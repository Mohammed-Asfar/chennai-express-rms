import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../core/api/api_exception.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/utils/money.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/search_field.dart';
import '../../menu/data/menu_models.dart';
import '../../menu/data/menu_repository.dart';

/// The menu side of the order screen: search, category filters, and a grid of
/// items sized for fast tapping.
class MenuPanel extends ConsumerStatefulWidget {
  const MenuPanel({
    super.key,
    required this.onPick,
    required this.enabled,
    this.surcharge = 0,
  });

  /// Called with the chosen variant. Portion selection happens here, so the
  /// order screen only ever receives a concrete variant.
  final void Function(MenuVariant variant) onPick;
  final bool enabled;

  /// Paise this table's section adds to each item.
  ///
  /// The prices shown include it, because a cashier reading ₹75 off the screen
  /// and then seeing ₹85 on the bill has no way to tell a surcharge from a
  /// mistake. An item may exempt itself, which [MenuItem.priceIn] handles.
  final int surcharge;

  @override
  ConsumerState<MenuPanel> createState() => _MenuPanelState();
}

class _MenuPanelState extends ConsumerState<MenuPanel> {
  String? _categoryId;
  String _search = '';

  // Owned here rather than inside SearchField, because adding an item has to
  // reach in and reset the box.
  final _searchController = TextEditingController();
  final _searchFocus = FocusNode();
  final _gridScroll = ScrollController();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocus.dispose();
    _gridScroll.dispose();
    super.dispose();
  }

  /// Empties the search and puts the caret back in it.
  ///
  /// An order is typed one dish after another. Leaving the last query in place
  /// means the grid still shows a filtered menu the cashier has to clear by
  /// hand before the next item, and leaving focus on the tapped tile means
  /// typing goes nowhere. Both together are what makes adding a second item
  /// feel slower than the first.
  void _resetSearch() {
    _searchController.clear();
    setState(() {
      _search = '';
      _highlight = 0;
    });
    _searchFocus.requestFocus();
  }

  /// The tile the arrow keys are sitting on, as an index into the visible list.
  ///
  /// Kept rather than moving real focus onto the tiles, because focus has to
  /// stay in the search box: the point is to type a few letters, arrow to the
  /// dish and press Enter without ever leaving the keyboard. Moving focus to a
  /// tile would mean the next keystroke went nowhere.
  int _highlight = 0;

  // The grid's own geometry, repeated here because the scroll offset of a row
  // has to be worked out before that row has been built.
  static const double _tileExtent = 200;
  static const double _tileHeight = 104;
  static const double _gridSpacing = AppSpacing.md;
  static const double _gridPadding = AppSpacing.lg;

  /// How many tiles fit across, matching the grid's own arithmetic.
  ///
  /// Up and Down move by a row, so this has to be the real column count, and
  /// [width] must be the width the grid is laid out in — not the panel's, which
  /// includes the category rail.
  ///
  /// Mirrors SliverGridDelegateWithMaxCrossAxisExtent: it fits
  /// ceil(width / (maxExtent + spacing)) columns into the padded width.
  int _columns(double width) {
    final usable = width - _gridPadding * 2;
    final count = (usable / (_tileExtent + _gridSpacing)).ceil();
    return count < 1 ? 1 : count;
  }

  /// Moves the highlight, keeping it inside the list.
  ///
  /// Clamped rather than wrapped: arrowing off the last dish and landing back
  /// on the first reads as the list having jumped, and a cashier holding Down
  /// to reach the end would cycle past it forever.
  void _move(int delta, int count, int columns) {
    if (count == 0) return;
    final next = (_highlight + delta).clamp(0, count - 1);
    if (next == _highlight) return;
    setState(() => _highlight = next);
    _revealHighlight(next, columns);
  }

  /// Brings the highlighted tile into view when arrowing past the fold.
  ///
  /// The grid is taller than the panel on a full menu, and a highlight that has
  /// scrolled out of sight is worse than none — the cashier presses Enter on a
  /// dish they cannot see.
  ///
  /// [columns] is passed in rather than recomputed: the only width available
  /// here is the whole panel's, which is wider than the grid by the category
  /// rail, and one column too many puts the highlight on the wrong row.
  void _revealHighlight(int index, int columns) {
    if (!_gridScroll.hasClients) return;

    // Laid out after the frame, because the row that has just been highlighted
    // may not have been built yet and the scroll extent would be short.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_gridScroll.hasClients) return;

      final position = _gridScroll.position;
      const rowStride = _tileHeight + _gridSpacing;

      // Rows sit below the grid's top padding, and the last one is followed by
      // the bottom padding — both count toward the offset a row rests at.
      final top = _gridPadding + (index ~/ columns) * rowStride;
      final bottom = top + _tileHeight;

      final double target;
      if (top < position.pixels) {
        // Off the top: bring the row's padding edge to the top of the viewport.
        target = top - _gridPadding;
      } else if (bottom > position.pixels + position.viewportDimension) {
        // Off the bottom: sit the row against the bottom edge.
        target = bottom + _gridPadding - position.viewportDimension;
      } else {
        return;
      }

      _gridScroll.jumpTo(target.clamp(0.0, position.maxScrollExtent));
    });
  }

  /// The dishes currently on show, in grid order.
  List<MenuItem> _visible(List<MenuItem> all) {
    return all.where((item) {
      if (_categoryId != null && item.categoryId != _categoryId) return false;
      if (_search.isEmpty) return true;
      return item.name.toLowerCase().contains(_search);
    }).toList();
  }

  /// Arrow keys walk the grid; Enter adds what they landed on.
  ///
  /// Handled here rather than on the tiles so that focus never leaves the
  /// search box — a cashier types "chick", arrows across to the right biriyani
  /// and presses Enter, without a hand leaving the keyboard.
  ///
  /// Only the keys we claim are consumed. Everything else falls through to the
  /// text field, or the arrow keys would stop moving the caret through a query
  /// being corrected.
  KeyEventResult _onKey(KeyEvent event, List<MenuItem> visible, double width) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (visible.isEmpty) return KeyEventResult.ignored;

    final columns = _columns(width);
    final key = event.logicalKey;

    if (key == LogicalKeyboardKey.arrowRight) {
      _move(1, visible.length, columns);
    } else if (key == LogicalKeyboardKey.arrowLeft) {
      _move(-1, visible.length, columns);
    } else if (key == LogicalKeyboardKey.arrowDown) {
      _move(columns, visible.length, columns);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _move(-columns, visible.length, columns);
    } else if (key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.numpadEnter) {
      // Down only, never repeat. Arrows are fine to hold; Enter held down
      // would put the same dish on the order over and over.
      if (event is! KeyDownEvent) return KeyEventResult.handled;

      final index = _highlight.clamp(0, visible.length - 1);
      final item = visible[index];
      // Same gate the tile applies. An unavailable dish must not be addable by
      // keyboard when it cannot be tapped.
      if (widget.enabled && item.canOrder) _pick(item);
    } else {
      return KeyEventResult.ignored;
    }

    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(categoriesProvider);
    final items = ref.watch(menuItemsProvider);
    final theme = Theme.of(context);

    // Categories down the right, not across the top.
    //
    // Sixteen of them never fitted on one line, and a horizontal strip meant
    // scrolling sideways to find a category and then back again for the next
    // order. A column shows every name in full, in the order they appear on the
    // printed card, so staff learn where things sit and stop reading.
    //
    // On the right because the item grid is what the eye works through, and a
    // filter belongs beside the results rather than in front of them.
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(child: _items(context, items, theme)),
        categories.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (list) => _CategoryRail(
            categories: list,
            selectedId: _categoryId,
            onSelect: (id) => setState(() => _categoryId = id),
          ),
        ),
      ],
    );
  }

  Widget _items(BuildContext context, AsyncValue<List<MenuItem>> items, ThemeData theme) {
    // The key handler needs the same list the grid draws, and the width it is
    // drawn at, to know how many tiles make a row.
    return LayoutBuilder(
      builder: (context, constraints) {
        final visible = _visible(items.valueOrNull ?? const []);
        return Focus(
          // Does not take focus itself — it sits above the search box and reads
          // the keys on their way through.
          canRequestFocus: false,
          onKeyEvent: (_, event) => _onKey(event, visible, constraints.maxWidth),
          child: _body(context, items, theme, visible),
        );
      },
    );
  }

  Widget _body(
    BuildContext context,
    AsyncValue<List<MenuItem>> items,
    ThemeData theme,
    List<MenuItem> visible,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.md,
          ),
          child: SearchField(
            hintText: 'Search the menu',
            controller: _searchController,
            focusNode: _searchFocus,
            // Focused on arrival, so the first dish of an order is typed
            // straight away and the arrow keys work without a click first.
            autofocus: true,
            // Typing narrows the list, so the old position is meaningless —
            // start again at the first match, which is what a cashier expects
            // to add when they stop typing.
            onChanged: (value) => setState(() {
              _search = value;
              _highlight = 0;
            }),
          ),
        ),

        Expanded(
          child: items.when(
            loading: () => const AppLoading(),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ErrorBanner(message: userMessage(error)),
            ),
            data: (all) {
              if (visible.isEmpty) {
                return Center(
                  child: Text(
                    all.isEmpty
                        ? 'The menu is empty. Add items in Settings.'
                        : 'Nothing matches “$_search”',
                    style: theme.textTheme.bodyMedium,
                  ),
                );
              }

              return GridView.builder(
                controller: _gridScroll,
                padding: const EdgeInsets.fromLTRB(
                  AppSpacing.lg,
                  0,
                  AppSpacing.lg,
                  AppSpacing.lg,
                ),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 200,
                  mainAxisExtent: 104,
                  crossAxisSpacing: AppSpacing.md,
                  mainAxisSpacing: AppSpacing.md,
                ),
                itemCount: visible.length,
                itemBuilder: (context, index) => _ItemTile(
                  item: visible[index],
                  enabled: widget.enabled,
                  surcharge: widget.surcharge,
                  highlighted: index == _highlight,
                  onTap: () => _pick(visible[index]),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Future<void> _pick(MenuItem item) async {
    // A single-portion item adds straight away; several prompt first. Making
    // staff confirm "Standard" on every tap would slow service for nothing.
    if (!item.hasChoice) {
      final variant = item.variants.first;
      if (variant.isAvailable) {
        widget.onPick(variant);
        _resetSearch();
      }
      return;
    }

    final chosen = await showDialog<MenuVariant>(
      context: context,
      builder: (_) => _VariantPicker(item: item, surcharge: widget.surcharge),
    );

    // The dialog is awaited, so the panel may be gone by now.
    if (!mounted) return;

    // Only when something was added. A cancelled picker leaves the query alone
    // — the cashier is still looking for that dish.
    if (chosen != null) {
      widget.onPick(chosen);
      _resetSearch();
    }
  }
}

/// The category list down the right-hand edge.
class _CategoryRail extends StatelessWidget {
  const _CategoryRail({
    required this.categories,
    required this.selectedId,
    required this.onSelect,
  });

  final List<MenuCategory> categories;
  final String? selectedId;
  final ValueChanged<String?> onSelect;

  /// Wide enough for the longest name on the card — "Fried Rice & Noodles -
  /// Non Veg" — over two lines without cramping.
  static const double width = 184;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      decoration: const BoxDecoration(
        color: AppColors.surface,
        border: Border(left: BorderSide(color: AppColors.border)),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
        children: [
          _CategoryRow(
            label: 'All',
            selected: selectedId == null,
            onTap: () => onSelect(null),
          ),
          for (final category in categories)
            _CategoryRow(
              label: category.name,
              selected: selectedId == category.id,
              onTap: () => onSelect(category.id),
            ),
        ],
      ),
    );
  }
}

class _CategoryRow extends StatefulWidget {
  const _CategoryRow({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CategoryRow> createState() => _CategoryRowState();
}

class _CategoryRowState extends State<_CategoryRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = widget.selected;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: AppSpacing.minTapTarget),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            // A tint alone measured 1.01:1 against the surface — invisible.
            // The solid bar down the leading edge is what actually marks the
            // selection; the wash only supports it.
            color: selected
                ? AppColors.accentTint
                : _hovered
                    ? AppColors.surfaceHover
                    : null,
            border: Border(
              left: BorderSide(
                color: selected ? AppColors.accent : Colors.transparent,
                width: 3,
              ),
            ),
          ),
          alignment: Alignment.centerLeft,
          child: Text(
            widget.label,
            style: theme.textTheme.bodyMedium?.copyWith(
              color: selected ? AppColors.ink : AppColors.inkMuted,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ),
      ),
    );
  }
}

class _ItemTile extends StatefulWidget {
  const _ItemTile({
    required this.item,
    required this.enabled,
    required this.onTap,
    this.surcharge = 0,
    this.highlighted = false,
  });

  final MenuItem item;
  final bool enabled;
  final VoidCallback onTap;

  /// Where the arrow keys are sitting. Drawn like hover, because it means the
  /// same thing — this is what activating now would add.
  final bool highlighted;

  /// Paise this table's section adds. Already in the price shown.
  final int surcharge;

  @override
  State<_ItemTile> createState() => _ItemTileState();
}

class _ItemTileState extends State<_ItemTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = widget.item;
    final canOrder = widget.enabled && item.canOrder;

    // The keyboard highlight reads the same as hover, with a heavier border so
    // it survives on a screen where a mouse is also sitting over something.
    final marked = (_hovered || widget.highlighted) && canOrder;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: canOrder ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: widget.highlighted && canOrder
              ? AppColors.accentTint
              : marked
                  ? AppColors.surfaceHover
                  : AppColors.surface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(
            color: marked ? AppColors.accent : AppColors.border,
            width: widget.highlighted && canOrder ? 2 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: canOrder ? widget.onTap : null,
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    item.name,
                    style: theme.textTheme.bodyLarge,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        // The price this table will actually be charged, not
                        // the menu price. Reading ₹75 here and seeing ₹85 on
                        // the bill is indistinguishable from a mistake.
                        child: item.singlePriceIn(widget.surcharge) != null
                            ? Text(
                                Money.formatWithSymbol(
                                  item.singlePriceIn(widget.surcharge)!,
                                ),
                                style: theme.textTheme.bodyMedium?.copyWith(
                                  color: AppColors.accent,
                                  fontFamily: null,
                                ),
                              )
                            : Text(
                                '${item.variants.length} sizes',
                                style: theme.textTheme.bodySmall,
                              ),
                      ),
                      if (item.hasChoice)
                        Icon(
                          Icons.more_horiz,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _VariantPicker extends StatelessWidget {
  const _VariantPicker({required this.item, this.surcharge = 0});

  final MenuItem item;

  /// Paise this table's section adds. Already in the prices shown.
  final int surcharge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Text(item.name),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final variant in item.variants)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
                title: Text(variant.name),
                trailing: Text(
                  Money.formatWithSymbol(item.priceIn(variant, surcharge)),
                  style: theme.textTheme.titleMedium?.copyWith(color: AppColors.accent),
                ),
                // A sold-out portion stays visible but cannot be picked, so
                // staff can tell the customer rather than wondering where it went.
                enabled: variant.isAvailable,
                subtitle: variant.isAvailable ? null : const Text('Sold out'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                onTap: () => Navigator.of(context).pop(variant),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
      ],
    );
  }
}
