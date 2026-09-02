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
  });

  final String hintText;

  /// Called with the trimmed, lowercased query. Empty means "show everything".
  final ValueChanged<String> onChanged;

  final bool autofocus;

  @override
  State<SearchField> createState() => _SearchFieldState();
}

class _SearchFieldState extends State<SearchField> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: _controller,
      autofocus: widget.autofocus,
      decoration: InputDecoration(
        hintText: widget.hintText,
        prefixIcon: const Icon(Icons.search, size: 20),
        isDense: true,
        // A clear button rather than only backspace: a stale query is the
        // reason a list looks empty, and getting back to everything should be
        // one tap.
        suffixIcon: _controller.text.isEmpty
            ? null
            : IconButton(
                icon: const Icon(Icons.close, size: 18),
                tooltip: 'Clear',
                onPressed: () {
                  _controller.clear();
                  widget.onChanged('');
                  setState(() {});
                },
              ),
      ),
      onChanged: (value) {
        widget.onChanged(value.trim().toLowerCase());
        // Rebuilds only to show or hide the clear button.
        setState(() {});
      },
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
