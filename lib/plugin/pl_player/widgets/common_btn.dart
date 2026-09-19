import 'package:material_ui/material_ui.dart';

class ComBtn extends StatelessWidget {
  final Widget icon;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final VoidCallback? onSecondaryTap;
  final void Function(PointerDownEvent event)? onPointerDown;
  final void Function(PointerUpEvent event)? onPointerUp;
  final void Function(PointerCancelEvent event)? onPointerCancel;
  final double width;
  final double height;
  final String? tooltip;
  final String? semanticIdentifier;

  const ComBtn({
    super.key,
    required this.icon,
    this.onTap,
    this.onLongPress,
    this.onSecondaryTap,
    this.onPointerDown,
    this.onPointerUp,
    this.onPointerCancel,
    this.width = 34,
    this.height = 34,
    this.tooltip,
    this.semanticIdentifier,
  });

  @override
  Widget build(BuildContext context) {
    final child = Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: onPointerDown,
      onPointerUp: onPointerUp,
      onPointerCancel: onPointerCancel,
      child: SizedBox(
        width: width,
        height: height,
        child: GestureDetector(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onSecondaryTap,
          behavior: HitTestBehavior.opaque,
          child: icon,
        ),
      ),
    );
    final semanticChild = (tooltip != null || semanticIdentifier != null)
        ? Semantics(
            container: true,
            button: onTap != null || onSecondaryTap != null,
            enabled: onTap != null,
            label: tooltip,
            identifier: semanticIdentifier,
            onTap: onTap,
            onLongPress: onLongPress,
            child: child,
          )
        : child;
    if (tooltip != null) {
      return Tooltip(message: tooltip, child: semanticChild);
    }
    return semanticChild;
  }
}
