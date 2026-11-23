import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../theme/motion.dart';

/// The search box at the top of a list: a magnifier, the field, and a clear
/// button once something is typed. The accent ring shows while it has focus.
class SearchField extends StatefulWidget {
  const SearchField({super.key, required this.controller, required this.label, required this.hint, required this.clearLabel});

  final TextEditingController controller;

  /// What a screen reader calls the field.
  final String label;

  /// The placeholder.
  final String hint;

  /// The clear button's tooltip.
  final String clearLabel;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final focused = _focus.hasFocus;
    final reduced = Motion.reduced(context);
    return AnimatedContainer(
      duration: reduced ? Duration.zero : Motion.colour,
      height: 46,
      padding: const EdgeInsets.only(left: 14, right: 10),
      decoration: BoxDecoration(
        color: p.paper,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: focused ? b.accentLine : p.divider),
        boxShadow: [BoxShadow(color: focused ? b.accentSoft : b.accentSoft.withValues(alpha: 0), spreadRadius: 4)],
      ),
      child: Row(
        children: [
          Icon(Icons.search_rounded, size: 20, color: b.faint),
          const SizedBox(width: 10),
          Expanded(
            // The field is named by its label, as the web field was by its aria-label
            child: MergeSemantics(
              child: Semantics(
                label: widget.label,
                child: TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: widget.controller,
                  focusNode: _focus,
                  textInputAction: TextInputAction.search,
                  style: TextStyle(fontFamily: fontSans, fontSize: 15, color: p.text),
                  decoration: InputDecoration(
                    hintText: widget.hint,
                    hintStyle: TextStyle(fontFamily: fontSans, fontSize: 15, color: b.faint),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
          ),
          if (widget.controller.text.isNotEmpty)
            IconButton(
              onPressed: widget.controller.clear,
              tooltip: widget.clearLabel,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                backgroundColor: b.raised,
                foregroundColor: p.textSecondary,
                fixedSize: const Size.square(26),
                minimumSize: const Size.square(26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.close_rounded, size: 15),
            ),
        ],
      ),
    );
  }
}
