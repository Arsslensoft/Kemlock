import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../ui/ui.dart';
import 'service_hue.dart';
import 'service_icons.dart';

/// The service's logo on its brand colour, else a monogram tinted with its
/// hue, as `ServiceTile.tsx` drew it. The logos load on first use; until
/// then, and for services without one, the monogram shows.
class ServiceTile extends ConsumerWidget {
  const ServiceTile({super.key, required this.name, this.size = 44});

  final String name;
  final double size;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final trimmed = name.trim();
    final icon = trimmed.isEmpty ? null : ref.watch(serviceIconsProvider).value?.iconFor(trimmed);
    final radius = BorderRadius.circular((size * 0.32).roundToDouble());

    if (icon != null) {
      return ExcludeSemantics(
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: Color(int.parse('FF${icon.hex}', radix: 16)),
            borderRadius: radius,
            // Near-black brands would vanish into the dark background without an edge
            border: Border.all(color: context.palette.divider),
          ),
          child: SvgPicture.string(
            icon.svg(fill: isLightBrand(icon.hex) ? '#0A0B0D' : '#FFFFFF'),
            width: (size * 0.5).roundToDouble(),
            height: (size * 0.5).roundToDouble(),
          ),
        ),
      );
    }

    final dark = Theme.of(context).brightness == Brightness.dark;
    final hue = serviceHue(trimmed).toDouble();
    final Color background;
    final Color foreground;
    if (trimmed.isEmpty) {
      background = context.bmc.raised;
      foreground = context.bmc.faint;
    } else if (dark) {
      background = HSLColor.fromAHSL(.16, hue, .70, .62).toColor();
      foreground = HSLColor.fromAHSL(1, hue, .80, .74).toColor();
    } else {
      background = HSLColor.fromAHSL(.14, hue, .70, .45).toColor();
      foreground = HSLColor.fromAHSL(1, hue, .75, .33).toColor();
    }
    return ExcludeSemantics(
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 400),
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: background, borderRadius: radius),
        child: Text(
          trimmed.isEmpty ? '?' : trimmed.characters.first.toUpperCase(),
          style: TextStyle(
            fontFamily: fontSans,
            fontSize: (size * 0.41).roundToDouble(),
            fontWeight: FontWeight.w600,
            height: 1,
            color: foreground,
          ),
        ),
      ),
    );
  }
}
