import 'package:flutter/material.dart';
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
  const MenuPanel({super.key, required this.onPick, required this.enabled});

  /// Called with the chosen variant. Portion selection happens here, so the
  /// order screen only ever receives a concrete variant.
  final void Function(MenuVariant variant) onPick;
  final bool enabled;

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

        categories.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (list) => SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.lg),
              children: [
                _CategoryChip(
                  label: 'All',
                  selected: _categoryId == null,
                  onTap: () => setState(() => _categoryId = null),
                ),
                for (final category in list)
                  _CategoryChip(
                    label: category.name,
                    selected: _categoryId == category.id,
                    onTap: () => setState(() => _categoryId = category.id),
                  ),
              ],
            ),
          ),
        ),

        const SizedBox(height: AppSpacing.md),

        Expanded(
          child: items.when(
            loading: () => const AppLoading(),
            error: (error, _) => Padding(
              padding: const EdgeInsets.all(AppSpacing.lg),
              child: ErrorBanner(message: '$error'),
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
      builder: (_) => _VariantPicker(item: item),
    );
    if (chosen != null) widget.onPick(chosen);
  }
}

class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: AppSpacing.sm),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _ItemTile extends StatefulWidget {
  const _ItemTile({required this.item, required this.enabled, required this.onTap});

  final MenuItem item;
  final bool enabled;
  final VoidCallback onTap;

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
                        child: item.singlePrice != null
                            ? Text(
                                Money.formatWithSymbol(item.singlePrice!),
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
  const _VariantPicker({required this.item});

  final MenuItem item;

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
                  Money.formatWithSymbol(variant.price),
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
