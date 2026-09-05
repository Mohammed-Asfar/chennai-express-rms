import 'package:flutter/material.dart';
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
            onChanged: (value) => setState(() => _search = value),
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
              final visible = all.where((item) {
                if (_categoryId != null && item.categoryId != _categoryId) return false;
                if (_search.isEmpty) return true;
                return item.name.toLowerCase().contains(_search);
              }).toList();

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
      if (variant.isAvailable) widget.onPick(variant);
      return;
    }

    final chosen = await showDialog<MenuVariant>(
      context: context,
      builder: (_) => _VariantPicker(item: item, surcharge: widget.surcharge),
    );
    if (chosen != null) widget.onPick(chosen);
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
  });

  final MenuItem item;
  final bool enabled;
  final VoidCallback onTap;

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

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: canOrder ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: _hovered && canOrder ? AppColors.surfaceHover : AppColors.surface,
          borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
          border: Border.all(
            color: _hovered && canOrder ? AppColors.accent : AppColors.border,
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
