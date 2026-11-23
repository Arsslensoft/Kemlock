import 'dart:ui';

import 'package:flutter/material.dart';

import '../i18n/messages.dart';
import '../ui/ui.dart';

/// The four tabs, in order.
enum AppTab {
  codes('/accounts', 'nav.codes', Icons.password_rounded),
  backup('/backup', 'nav.backup', Icons.confirmation_number_outlined),
  vault('/vault', 'nav.vault', Icons.inventory_2_outlined),
  settings('/settings', 'nav.settings', Icons.tune_rounded);

  const AppTab(this.path, this.labelId, this.icon);

  final String path;
  final String labelId;
  final IconData icon;

  /// The tab a location belongs to: About and Terms sit under Settings.
  static AppTab of(String location) {
    if (location.startsWith('/backup')) return backup;
    if (location.startsWith('/vault')) return vault;
    if (location.startsWith('/accounts') || location == '/') return codes;
    return settings;
  }
}

/// The floating glass tab bar with a sliding active pill, which glows, and
/// the primary Add button beside it with its halo and its standing glow, as
/// `TabBar.tsx` drew them and the mockups of add-visual-effects light them.
class AppTabBar extends StatelessWidget {
  const AppTabBar({super.key, required this.active, required this.onSelect, required this.addLabel, required this.onAdd});

  final AppTab active;
  final ValueChanged<AppTab> onSelect;
  final String addLabel;
  final VoidCallback onAdd;

  static const height = 62.0;

  @override
  Widget build(BuildContext context) {
    final bmc = context.bmc;
    final palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 568),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              label: context.t('nav.label'),
              explicitChildNodes: true,
              child: Container(
                height: height,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(31),
                  border: Border.all(color: bmc.line2),
                  boxShadow: bmc.shadow,
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(31),
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
                    child: ColoredBox(
                      color: bmc.glass,
                      child: Padding(
                        padding: const EdgeInsets.all(5),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final width = constraints.maxWidth / AppTab.values.length;
                            return Stack(
                              children: [
                                AnimatedPositioned(
                                  duration: Motion.thumb,
                                  curve: Ease.sheet,
                                  left: width * active.index,
                                  top: 0,
                                  width: width,
                                  height: 50,
                                  child: Glow(
                                    borderRadius: BorderRadius.circular(25),
                                    child: DecoratedBox(
                                      decoration: BoxDecoration(color: bmc.accentSoft, borderRadius: BorderRadius.circular(25)),
                                    ),
                                  ),
                                ),
                                Row(
                                  children: [
                                    for (final tab in AppTab.values)
                                      Expanded(
                                        child: _TabButton(
                                          tab: tab,
                                          selected: tab == active,
                                          onTap: () => onSelect(tab),
                                          selectedColor: bmc.accentText,
                                          color: palette.textSecondary,
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            );
                          },
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          PressScale(
            scale: .94,
            child: Semantics(
              button: true,
              label: addLabel,
              excludeSemantics: true,
              child: GestureDetector(
                onTap: onAdd,
                child: Container(
                  width: height,
                  height: height,
                  decoration: BoxDecoration(color: palette.primary, shape: BoxShape.circle, boxShadow: StandingGlow.add(bmc)),
                  child: Stack(
                    clipBehavior: Clip.none,
                    alignment: Alignment.center,
                    children: [
                      const _AddHalo(),
                      Icon(Icons.add_rounded, size: 28, color: palette.onPrimary),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// The thin ring that spreads from the Add button and fades, every 2.8
/// seconds. It is laid out with room for the ring at its widest, 1.9 times
/// the button, so the layer it repaints is as large as what it paints.
class _AddHalo extends StatelessWidget {
  const _AddHalo();

  static const _room = AppTabBar.height * 0.45;

  @override
  Widget build(BuildContext context) => Positioned(
    left: -_room,
    top: -_room,
    right: -_room,
    bottom: -_room,
    child: IgnorePointer(
      child: ExcludeSemantics(
        child: RepaintBoundary(
          child: Padding(
            padding: const EdgeInsets.all(_room),
            child: Halo(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: context.palette.primary.withValues(alpha: 0.7)),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class _TabButton extends StatelessWidget {
  const _TabButton({required this.tab, required this.selected, required this.onTap, required this.selectedColor, required this.color});

  final AppTab tab;
  final bool selected;
  final VoidCallback onTap;
  final Color selectedColor;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? selectedColor : color;
    return PressScale(
      scale: .95,
      child: Semantics(
        button: true,
        selected: selected,
        label: context.t(tab.labelId),
        excludeSemantics: true,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: SizedBox(
            height: 50,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                AnimatedSwitcher(
                  duration: Motion.colour,
                  child: Icon(tab.icon, key: ValueKey(selected), size: 22, color: foreground),
                ),
                const SizedBox(height: 3),
                AnimatedDefaultTextStyle(
                  duration: Motion.colour,
                  style: TextStyle(
                    fontFamily: fontSans,
                    fontSize: 11,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                    color: foreground,
                  ),
                  child: Text(context.t(tab.labelId), maxLines: 1, overflow: TextOverflow.ellipsis),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
