import importlib.util
from pathlib import Path
from tempfile import TemporaryDirectory
import unittest

SPEC = importlib.util.spec_from_file_location(
    'routing_flutter_patches', Path(__file__).resolve().parents[1] / 'scripts/prepare_ohos_flutter.py')
PATCHES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PATCHES)

PREFIX = '    this.hitTestBehavior = HitTestBehavior.opaque,\n'
HORIZONTAL = '    this.horizontalDragGestureRecognizer = HorizontalDragGestureRecognizer.new,\n'
SUFFIX = '  }) : assert(semanticChildCount == null || semanticChildCount >= 0);'
CUSTOM = '''
  /// {@template flutter.widgets.Scrollable.axisDirection}
            _VerticalDragGestureRecognizer:
                      ..isDyAllowed = _isDyAllowed
  IsDyAllowed? isDyAllowed;
typedef IsDyAllowed = bool Function(double dy);
  bool isPointerAllowed(PointerEvent event) {
    return super.isPointerAllowed(event);
  }
'''
PLAIN = '''
  /// {@template flutter.widgets.Scrollable.axisDirection}
            VerticalDragGestureRecognizer:
                GestureRecognizerFactoryWithHandlers<VerticalDragGestureRecognizer>(
                  () => VerticalDragGestureRecognizer(supportedDevices: _configuration.dragDevices),
                  (VerticalDragGestureRecognizer instance) {
                    instance
                      ..onDown = _handleDragDown
'''
SCROLL_VIEW = '''    this.hitTestBehavior = HitTestBehavior.opaque,
  }) : assert(
  /// Returns the [AxisDirection] in which the scroll view scrolls.
      hitTestBehavior: hitTestBehavior,
      viewportBuilder:
    super.hitTestBehavior,
  });

  /// The slivers
'''


class RoutingPointerFilterTest(unittest.TestCase):
    def setUp(self):
        self.temp = TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        widgets = self.root / 'packages/flutter/lib/src/widgets'
        widgets.mkdir(parents=True)
        self.scrollable = widgets / 'scrollable.dart'
        self.scroll_view = widgets / 'scroll_view.dart'
        self.scroll_view.write_text(SCROLL_VIEW)

    def apply_and_check(self, *, horizontal=False, custom=True):
        source = PREFIX + (HORIZONTAL if horizontal else '') + SUFFIX + (CUSTOM if custom else PLAIN)
        self.scrollable.write_text(source)
        self.assertEqual(PATCHES.patch_pointer_filter(self.root), 2)
        updated = self.scrollable.read_text()
        self.assertEqual(updated.count('this.pointerDownFilter,'), 1)
        self.assertIn('..pointerDownFilter = widget.pointerDownFilter', updated)
        self.assertIn('pointerDownFilter?.call(event) == false', updated)
        if custom:
            self.assertIn('..isDyAllowed = _isDyAllowed', updated)
            self.assertIn('IsDyAllowed? isDyAllowed;', updated)
        if horizontal:
            self.assertIn(HORIZONTAL, updated)
        self.assertIn('super.pointerDownFilter,', self.scroll_view.read_text())
        self.assertEqual(PATCHES.patch_pointer_filter(self.root), 0)
        self.assertEqual(self.scrollable.read_text(), updated)

    def test_existing_custom_shape_is_preserved_and_idempotent(self):
        self.apply_and_check()

    def test_prior_horizontal_patch_is_preserved_and_idempotent(self):
        self.apply_and_check(horizontal=True)

    def test_unmodified_standard_shape_remains_supported(self):
        self.apply_and_check(custom=False)

    def test_unknown_constructor_is_rejected_without_writing(self):
        source = PREFIX + '    this.unreviewedOption,\n' + SUFFIX + CUSTOM
        self.scrollable.write_text(source)
        with self.assertRaises(SystemExit):
            PATCHES.patch_pointer_filter(self.root)
        self.assertEqual(self.scrollable.read_text(), source)
        self.assertEqual(self.scroll_view.read_text(), SCROLL_VIEW)

    def test_duplicate_constructor_is_rejected_without_writing(self):
        source = (PREFIX + SUFFIX) * 2 + CUSTOM
        self.scrollable.write_text(source)
        with self.assertRaises(SystemExit):
            PATCHES.patch_pointer_filter(self.root)
        self.assertEqual(self.scrollable.read_text(), source)

    def test_partial_filter_still_fails_closed(self):
        source = PREFIX + '    this.pointerDownFilter,\n' + SUFFIX + CUSTOM
        self.scrollable.write_text(source)
        with self.assertRaises(SystemExit):
            PATCHES.patch_pointer_filter(self.root)
        self.assertEqual(self.scrollable.read_text(), source)


if __name__ == '__main__':
    unittest.main()
