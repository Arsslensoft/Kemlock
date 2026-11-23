import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../theme/app_theme.dart';

/// The Kemlock icon: a K with a keyhole cut into its stem, on a gunmetal
/// tile. It is decoration, so screen readers skip it.
///
/// The icon is drawn from `assets/brand/`, where `tool/icons/build_svgs.mjs`
/// writes it. At 48 and under it uses the plainer small icon, as the design
/// does.
class BrandMark extends StatelessWidget {
  const BrandMark({super.key, this.size = 22});

  final double size;

  static const asset = 'assets/brand/kemlock-icon.svg';
  static const smallAsset = 'assets/brand/kemlock-icon-small.svg';

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: SvgPicture.asset(size <= 48 ? smallAsset : asset, width: size, height: size),
    );
  }
}

/// The Kemlock wordmark: the keyhole K, then "emlock" in steel on the dark
/// theme and gunmetal on the light one. [label] is what screen readers say.
class BrandWordmark extends StatelessWidget {
  const BrandWordmark({super.key, this.height = 24, required this.label});

  final double height;
  final String label;

  static const darkAsset = 'assets/brand/kemlock-wordmark-dark.svg';
  static const lightAsset = 'assets/brand/kemlock-wordmark-light.svg';

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(context.palette.isDark ? darkAsset : lightAsset, height: height, semanticsLabel: label);
  }
}
