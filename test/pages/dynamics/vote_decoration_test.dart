import 'package:PiliPlus/pages/dynamics/widgets/vote_decoration.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  for (final scenario in <({String name, double alpha, double inset})>[
    (name: 'opaque', alpha: 1.0, inset: 4.0),
    (name: 'rounds to opaque', alpha: 0.999, inset: 4.0),
    (name: 'rounds below opaque', alpha: 0.997, inset: 0.0),
    (name: '8-bit translucent', alpha: 254 / 255, inset: 0.0),
    (name: 'transparent', alpha: 0.0, inset: 0.0),
  ]) {
    test('vote fill keeps quantized opacity geometry: ${scenario.name}', () {
      const fill = Color(0xff336699);
      final painter = VoteDecoration(
        color: fill,
        percentage: 1,
        border: Border.all(
          width: 8,
          color: Color.from(alpha: scenario.alpha, red: 0.2, green: 0.4, blue: 0.6),
        ),
        borderRadius: BorderRadius.circular(6),
      ).createBoxPainter(() {});
      addTearDown(painter.dispose);
      final expected = RRect.fromRectAndRadius(
        const Rect.fromLTWH(0, 0, 100, 60).deflate(scenario.inset),
        const Radius.circular(6),
      );
      expect(
        (Canvas canvas) => painter.paint(
          canvas,
          Offset.zero,
          const ImageConfiguration(size: Size(100, 60), textDirection: TextDirection.ltr),
        ),
        paints..rrect(rrect: expected, color: fill),
      );
    });
  }

  test('a non-painted border does not inset the vote fill', () {
    const fill = Color(0xff336699);
    final painter = VoteDecoration(
      color: fill,
      percentage: 1,
      border: Border.all(width: 8, style: BorderStyle.none),
      borderRadius: BorderRadius.zero,
    ).createBoxPainter(() {});
    addTearDown(painter.dispose);
    expect(
      (Canvas canvas) => painter.paint(
        canvas,
        Offset.zero,
        const ImageConfiguration(size: Size(100, 60), textDirection: TextDirection.ltr),
      ),
      paints..rrect(
        rrect: RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 60), Radius.zero),
        color: fill,
      ),
    );
  });
}
