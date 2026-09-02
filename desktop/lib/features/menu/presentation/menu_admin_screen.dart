import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../../core/widgets/search_field.dart';
import '../data/menu_admin_models.dart';
import '../data/menu_admin_repository.dart';
import '../data/menu_repository.dart';
import 'category_dialog.dart';
import 'item_editor_dialog.dart';
import 'item_row.dart';

/// Menu management: categories down the left, the dishes in one on the right.
///
/// Two panes rather than a nested tree — a category is a filter, and staff
/// editing the Biryani prices want to see only biryani while they do it.
class MenuAdminScreen extends ConsumerStatefulWidget {
  const MenuAdminScreen({super.key});

  @override
  ConsumerState<MenuAdminScreen> createState() => _MenuAdminScreenState();
}

class _MenuAdminScreenState extends ConsumerState<MenuAdminScreen> {
  String? _selectedCategoryId;

  @override
  Widget build(BuildContext context) {
    final categories = ref.watch(adminCategoriesProvider);
    final items = ref.watch(adminItemsProvider);

    return categories.when(
      loading: () => const AppLoading(message: 'Loading the menu'),
      error: (error, _) => _fullWidthError('$error'),
      data: (categoryList) {
        if (categoryList.isEmpty) {
          return _EmptyMenu(onCreate: () => _createCategory(context));
        }

        // Selection survives a refresh, but not a category being deleted.
        final selectedId = categoryList.any((c) => c.id == _selectedCategoryId)
            ? _selectedCategoryId!
            : categoryList.first.id;

        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _CategoryPane(
              categories: categoryList,
              selectedId: selectedId,
              onSelect: (id) => setState(() => _selectedCategoryId = id),
              onCreate: () => _createCategory(context),
              onRename: (c) => _renameCategory(context, c),
              onDelete: (c) => _deleteCategory(context, c),
              onReorder: (ids) => _reorderCategories(context, ids),
            ),
            Container(width: 1, color: AppColors.border),
            Expanded(
              child: items.when(
                loading: () => const AppLoading(message: 'Loading dishes'),
                error: (error, _) => _fullWidthError('$error'),
                data: (allItems) {
                  final forCategory =
                      allItems.where((i) => i.categoryId == selectedId).toList();
                  return _ItemPane(
                    categories: categoryList,
                    categoryId: selectedId,
                    items: forCategory,
                    onChanged: _refresh,
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _fullWidthError(String message) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ErrorBanner(message: message),
          ),
        ),
      );

  /// Saves the order after a drag.
  ///
  /// The list is sent whole rather than as a moved index: the backend numbers
  /// them from the order it is given, so a dropped request cannot leave two
  /// categories claiming the same position.
  Future<void> _reorderCategories(BuildContext context, List<String> ids) async {
    try {
      await ref.read(menuAdminRepositoryProvider).reorderCategories(ids);
      _refresh();
    } on ApiException catch (error) {
      if (!context.mounted) return;
      // The list has already moved on screen; refreshing puts it back.
      _refresh();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  void _refresh() {
    ref.invalidate(adminCategoriesProvider);
    ref.invalidate(adminItemsProvider);

    // The till reads the menu through its own providers. Without this, a dish
    // added here would not appear on the order screen until the app restarted.
    ref.invalidate(categoriesProvider);
    ref.invalidate(menuItemsProvider);
  }

  Future<void> _createCategory(BuildContext context) async {
    final created = await CategoryDialog.show(context);
    if (created == true) _refresh();
  }

  Future<void> _renameCategory(BuildContext context, AdminCategory category) async {
    final saved = await CategoryDialog.show(context, category: category);
    if (saved == true) _refresh();
  }

  Future<void> _deleteCategory(BuildContext context, AdminCategory category) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${category.name}?'),
        content: Text(
          category.itemCount > 0
              ? 'This category still holds ${category.itemCount} '
                  'dish${category.itemCount == 1 ? '' : 'es'}. Move them first.'
              : 'The category is empty and can be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: category.itemCount > 0
                ? null
                : () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(menuAdminRepositoryProvider).deleteCategory(category.id);
      _refresh();
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

/// The left pane: every category, with how many dishes each holds.
class _CategoryPane extends StatelessWidget {
  const _CategoryPane({
    required this.categories,
    required this.selectedId,
    required this.onSelect,
    required this.onCreate,
    required this.onRename,
    required this.onDelete,
    required this.onReorder,
  });

  final List<AdminCategory> categories;
  final String selectedId;
  final ValueChanged<String> onSelect;
  final VoidCallback onCreate;
  final ValueChanged<AdminCategory> onRename;
  final ValueChanged<AdminCategory> onDelete;

  /// The full list of ids in their new order, after a drag.
  final ValueChanged<List<String>> onReorder;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 260,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              AppSpacing.lg,
              AppSpacing.md,
              AppSpacing.sm,
            ),
            child: Row(
              children: [
                Text('CATEGORIES', style: theme.textTheme.labelSmall),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.add, size: 18),
                  tooltip: 'New category',
                  onPressed: onCreate,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
          Expanded(
            // Draggable, because the order here is the order the till shows.
            // Putting Biryani above Drinks is how a counter is made quick, and
            // it is not worth a settings screen of its own.
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              itemCount: categories.length,
              buildDefaultDragHandles: false,
              onReorder: (from, to) {
                // Flutter reports the destination before the moved row is
                // removed, so anything dragged downwards is one too far.
                final ids = categories.map((c) => c.id).toList();
                final target = to > from ? to - 1 : to;
                ids.insert(target, ids.removeAt(from));
                onReorder(ids);
              },
              itemBuilder: (context, index) {
                final category = categories[index];
                return ReorderableDragStartListener(
                  key: ValueKey(category.id),
                  index: index,
                  child: _CategoryTile(
                    category: category,
                    selected: category.id == selectedId,
                    onTap: () => onSelect(category.id),
                    onRename: () => onRename(category),
                    onDelete: () => onDelete(category),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTile extends StatefulWidget {
  const _CategoryTile({
    required this.category,
    required this.selected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  final AdminCategory category;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  @override
  State<_CategoryTile> createState() => _CategoryTileState();
}

class _CategoryTileState extends State<_CategoryTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final category = widget.category;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: SystemMouseCursors.click,
        child: Material(
          color: widget.selected
              ? AppColors.accentTint
              : _hovered
                  ? AppColors.surfaceHover
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpacing.md,
                vertical: AppSpacing.sm + 2,
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      category.name,
                      style: theme.textTheme.bodyLarge?.copyWith(
                        fontWeight:
                            widget.selected ? FontWeight.w600 : FontWeight.w400,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text('${category.itemCount}', style: theme.textTheme.bodySmall),
                  if (_hovered || widget.selected)
                    PopupMenuButton<String>(
                      icon: const Icon(Icons.more_horiz, size: 18),
                      tooltip: 'Category actions',
                      padding: EdgeInsets.zero,
                      onSelected: (value) {
                        if (value == 'rename') widget.onRename();
                        if (value == 'delete') widget.onDelete();
                      },
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: 'rename', child: Text('Rename')),
                        PopupMenuItem(value: 'delete', child: Text('Delete')),
                      ],
                    )
                  else
                    const SizedBox(width: AppSpacing.xl),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The right pane: the dishes in the selected category.
class _ItemPane extends ConsumerStatefulWidget {
  const _ItemPane({
    required this.categories,
    required this.categoryId,
    required this.items,
    required this.onChanged,
  });

  final List<AdminCategory> categories;
  final String categoryId;
  final List<AdminMenuItem> items;
  final VoidCallback onChanged;

  @override
  ConsumerState<_ItemPane> createState() => _ItemPaneState();
}

class _ItemPaneState extends ConsumerState<_ItemPane> {
  String _search = '';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final categories = widget.categories;
    final items = widget.items;
    final categoryName =
        categories.firstWhere((c) => c.id == widget.categoryId).name;

    // Name or portion: "half" is as reasonable a thing to type as "biryani".
    final shown = items.where((item) {
      if (_search.isEmpty) return true;
      if (item.name.toLowerCase().contains(_search)) return true;
      return item.variants.any((v) => v.name.toLowerCase().contains(_search));
    }).toList();

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
          child: Row(
            children: [
              Text(categoryName, style: theme.textTheme.titleLarge),
              const SizedBox(width: AppSpacing.sm),
              Text(
                '${items.length} dish${items.length == 1 ? '' : 'es'}',
                style: theme.textTheme.bodySmall,
              ),
              const Spacer(),
              ElevatedButton.icon(
                onPressed: () => _createItem(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add dish'),
              ),
            ],
          ),
        ),

        // Hidden when the category holds nothing: a search box over an empty
        // list is furniture, and the empty state has the useful action on it.
        if (items.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.lg,
              0,
              AppSpacing.lg,
              AppSpacing.md,
            ),
            child: SearchField(
              hintText: 'Search dishes in ${categoryName.toLowerCase()}',
              onChanged: (value) => setState(() => _search = value),
            ),
          ),

        Expanded(
          child: items.isEmpty
              ? _EmptyCategory(onAdd: () => _createItem(context, ref))
              : shown.isEmpty
              ? NoSearchResults(query: _search, noun: 'dishes')
              : ListView.builder(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg,
                    0,
                    AppSpacing.lg,
                    AppSpacing.xxl,
                  ),
                  itemCount: shown.length,
                  itemBuilder: (context, index) => ItemRow(
                    item: shown[index],
                    onEdit: () => _editItem(context, ref, shown[index]),
                    onToggle: (available) =>
                        _toggle(context, ref, shown[index], available),
                    onDelete: () => _deleteItem(context, ref, shown[index]),
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _createItem(BuildContext context, WidgetRef ref) async {
    final created = await ItemEditorDialog.show(
      context,
      categories: widget.categories,
      initialCategoryId: widget.categoryId,
    );
    if (created == true) widget.onChanged();
  }

  Future<void> _editItem(
    BuildContext context,
    WidgetRef ref,
    AdminMenuItem item,
  ) async {
    final saved = await ItemEditorDialog.show(
      context,
      categories: widget.categories,
      item: item,
    );
    if (saved == true) widget.onChanged();
  }

  /// Marking a dish unavailable is the everyday action — the kitchen runs out of
  /// prawns and the till should stop offering them, without deleting anything.
  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    AdminMenuItem item,
    bool available,
  ) async {
    try {
      await ref
          .read(menuAdminRepositoryProvider)
          .updateItem(item.id, isAvailable: available);
      widget.onChanged();
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _deleteItem(
    BuildContext context,
    WidgetRef ref,
    AdminMenuItem item,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${item.name}?'),
        content: const Text(
          'Past bills keep their own copy of the name and price, so history is '
          'not affected. To hide it from the till for now, switch it off instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(menuAdminRepositoryProvider).deleteItem(item.id);
      widget.onChanged();
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _EmptyMenu extends StatelessWidget {
  const _EmptyMenu({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.restaurant_menu,
              size: AppSpacing.xxl,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('No menu yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Start with a category — Starters, Biryani, Drinks — then add '
              'dishes to it.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton.icon(
              onPressed: onCreate,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New category'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyCategory extends StatelessWidget {
  const _EmptyCategory({required this.onAdd});

  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Nothing here yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Add the first dish to this category.',
            style: theme.textTheme.bodySmall,
          ),
          const SizedBox(height: AppSpacing.lg),
          ElevatedButton.icon(
            onPressed: onAdd,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add dish'),
          ),
        ],
      ),
    );
  }
}
