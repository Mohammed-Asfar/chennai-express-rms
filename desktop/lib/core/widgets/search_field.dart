import 'package:flutter/material.dart';
import '../theme/app_spacing.dart';

/// The search box above a list.
///
/// Shared because four screens carry one and they must behave identically —
/// staff learn the box once. It normalises the query itself (trimmed and
/// lowercased) so every caller filters against the same shape and no screen
/// re-normalises per row while typing.
class SearchField extends StatefulWidget {
  const SearchField({
    super.key,
    required this.hintText,
    required this.onChanged,
    this.autofocus = false,
    this.controller,
    this.focusNode,
  });

  final String hintText;

  /// Called with the trimmed, lowercased query. Empty means "show everything".
  final ValueChanged<String> onChanged;

  final bool autofocus;

  /// Supply both to drive the box from outside — the order screen clears and
  /// refocuses it after each item is added, so the next dish can be typed
  /// without reaching for the mouse.
  ///
  /// A caller that passes these owns them, and disposes them. Omit them and the
  /// field manages its own, which is what the screens that only ever filter do.
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  TextEditingController? _ownedController;

  TextEditingController get _controller =>
      widget.controller ?? (_ownedController ??= TextEditingController());

  @override
  void dispose() {
    // Only what this widget created. Disposing a caller's controller would
    // break the next field built with it.
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Listening to the controller rather than rebuilding from onChanged: the
    // text can also be cleared by whoever owns the controller, and a clear
    // button still showing over an empty box would be a lie.
    return ValueListenableBuilder<TextEditingValue>(
      valueListenable: _controller,
      builder: (context, value, _) => TextField(
        controller: _controller,
        focusNode: widget.focusNode,
        autofocus: widget.autofocus,
        decoration: InputDecoration(
          hintText: widget.hintText,
          prefixIcon: const Icon(Icons.search, size: 20),
          isDense: true,
          // A clear button rather than only backspace: a stale query is the
          // reason a list looks empty, and getting back to everything should be
          // one tap.
          suffixIcon: value.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: 'Clear',
                  onPressed: () {
                    _controller.clear();
                    widget.onChanged('');
                  },
                ),
        ),
        onChanged: (value) => widget.onChanged(value.trim().toLowerCase()),
      ),
    );
  }
}

/// Shown in place of a list when a search matches nothing.
///
/// Distinct from an empty day: "no bills today" and "no bills matching ravi"
/// need different answers, and showing the first when the second is true sends
/// someone looking for a bill that is really there.
class NoSearchResults extends StatelessWidget {
  const NoSearchResults({super.key, required this.query, required this.noun});

  final String query;

  /// Plural, lowercase — "bills", "dishes", "bookings", "tables".
  final String noun;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No $noun match "$query"', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Check the spelling, or clear the search.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}
