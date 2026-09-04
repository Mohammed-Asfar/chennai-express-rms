import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../../order/data/order_repository.dart';
import '../../order/presentation/order_screen.dart';
import '../../tables/data/table_admin_models.dart';
import '../../tables/data/table_admin_repository.dart';
import '../../tables/presentation/section_dialog.dart';
import '../../tables/presentation/table_dialog.dart';
import '../data/floor_models.dart';
import '../data/floor_repository.dart';
import 'add_table_tile.dart';
import 'table_card.dart';

/// The screen staff live on: every table, grouped by section, with who is
/// seated at each.
class FloorScreen extends ConsumerWidget {
  const FloorScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final floor = ref.watch(floorProvider);

    return floor.when(
      loading: () => const AppLoading(message: 'Loading the floor'),
      error: (error, _) => Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(AppSpacing.xl),
            child: ErrorBanner(message: '$error'),
          ),
        ),
      ),
      data: (sections) {
        // Empty sections are shown, not filtered out: a section with no tables
        // yet is exactly where someone needs the add tile.
        if (sections.isEmpty) {
          return _EmptyFloor(onAddSection: () => _addSection(context, ref));
        }

        return ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [
            for (final section in sections) ...[
              _SectionHeader(
                section: section,
                onRename: () => _renameSection(context, ref, section),
                onDelete: () => _deleteSection(context, ref, section),
                onMove: (direction) =>
                    _moveSection(context, ref, sections, section, direction),
                canMoveUp: section != sections.first,
                canMoveDown: section != sections.last,
              ),
              const SizedBox(height: AppSpacing.md),
              GridView.builder(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                  maxCrossAxisExtent: 184,
                  mainAxisExtent: 112,
                  crossAxisSpacing: AppSpacing.md,
                  mainAxisSpacing: AppSpacing.md,
                ),
                // One extra cell for the add tile, which sits with the tables
                // rather than in a toolbar — you notice a table is missing
                // while looking at the gap where it should be.
                itemCount: section.tables.length + 1,
                itemBuilder: (context, index) {
                  if (index == section.tables.length) {
                    return AddTableTile(
                      onTap: () => _addTables(context, ref, section.id),
                    );
                  }
                  final table = section.tables[index];
                  return TableCard(
                    table: table,
                    onTap: () => _openTable(context, ref, table),
                    onEdit: () => _editTable(context, ref, table),
                    onDelete: () => _deleteTable(context, ref, table),
                    // Only when nothing has been ordered on any of its
                    // parties. A table holding real food is freed by billing
                    // or cancelling, which asks for a reason.
                    onFree: table.parties.isNotEmpty &&
                            table.parties.every((p) => p.isEmpty)
                        ? () => _freeTable(context, ref, table)
                        : null,
                  );
                },
              ),
              const SizedBox(height: AppSpacing.xl),
            ],

            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => _addSection(context, ref),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('New section'),
              ),
            ),
          ],
        );
      },
    );
  }

  // --- setting up the floor -------------------------------------------------
  //
  // Layout changes live here rather than in Settings: the moment you notice a
  // table is missing is while looking at the floor.

  void _refresh(WidgetRef ref) {
    ref.invalidate(floorProvider);
    ref.invalidate(adminSectionsProvider);
    ref.invalidate(adminTablesProvider);
  }

  /// Moves a section a step up or down the floor.
  ///
  /// The whole ordered list is sent, not the one that moved: the backend
  /// numbers them from the order it is given, so a dropped request cannot
  /// leave two sections claiming the same position.
  Future<void> _moveSection(
    BuildContext context,
    WidgetRef ref,
    List<FloorSection> sections,
    FloorSection section,
    int direction,
  ) async {
    final ids = sections.map((s) => s.id).toList();
    final from = ids.indexOf(section.id);
    final to = from + direction;
    if (from < 0 || to < 0 || to >= ids.length) return;
    ids.insert(to, ids.removeAt(from));

    try {
      await ref.read(tableAdminRepositoryProvider).reorderSections(ids);
      _refresh(ref);
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// Discards the empty orders holding a table.
  ///
  /// A crash or a back-press used to strand an order with nothing on it, and
  /// the floor would show the table seated with no way to correct it. Nothing
  /// is lost: an order with no lines is a mis-tap.
  Future<void> _freeTable(
    BuildContext context,
    WidgetRef ref,
    DiningTable table,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Free ${table.name}?'),
        content: Text(
          table.parties.length == 1
              ? 'Nothing was ordered, so the order is discarded and the table '
                    'goes back to free.'
              : 'Nothing was ordered on any of the ${table.parties.length} '
                    'orders here. All of them are discarded.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Leave it'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Free it'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(orderRepositoryProvider);
    try {
      for (final party in table.parties) {
        await repository.cancel(
          party.orderId,
          'Discarded before anything was ordered',
        );
      }
      _refresh(ref);
      messenger.showSnackBar(SnackBar(content: Text('${table.name} is free')));
    } on ApiException catch (error) {
      _refresh(ref);
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _addSection(BuildContext context, WidgetRef ref) async {
    if (await SectionDialog.show(context) == true) _refresh(ref);
  }

  Future<void> _renameSection(
    BuildContext context,
    WidgetRef ref,
    FloorSection section,
  ) async {
    final existing = AdminSection(
      id: section.id,
      name: section.name,
      sortOrder: 0,
      isActive: true,
      tableCount: section.tables.length,
    );
    if (await SectionDialog.show(context, section: existing) == true) {
      _refresh(ref);
    }
  }

  Future<void> _deleteSection(
    BuildContext context,
    WidgetRef ref,
    FloorSection section,
  ) async {
    final blocked = section.tables.isNotEmpty;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${section.name}?'),
        content: Text(
          blocked
              ? 'This section still holds ${section.tables.length} '
                  'table${section.tables.length == 1 ? '' : 's'}. Remove them first.'
              : 'The section is empty and can be removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: blocked ? null : () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(tableAdminRepositoryProvider).deleteSection(section.id);
      _refresh(ref);
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _addTables(
    BuildContext context,
    WidgetRef ref,
    String sectionId,
  ) async {
    final sections = await ref.read(tableAdminRepositoryProvider).sections();
    if (!context.mounted) return;

    final created = await TableDialog.show(
      context,
      sections: sections,
      initialSectionId: sectionId,
    );
    if (created == true) _refresh(ref);
  }

  Future<void> _editTable(
    BuildContext context,
    WidgetRef ref,
    DiningTable table,
  ) async {
    final repo = ref.read(tableAdminRepositoryProvider);
    final sections = await repo.sections();
    if (!context.mounted) return;

    final existing = AdminTable(
      id: table.id,
      sectionId: table.sectionId,
      name: table.name,
      seats: table.seats,
      status: table.status.name,
      sortOrder: 0,
      isActive: true,
      partyCount: table.parties.length,
    );

    final saved = await TableDialog.show(
      context,
      sections: sections,
      table: existing,
    );
    if (saved == true) _refresh(ref);
  }

  Future<void> _deleteTable(
    BuildContext context,
    WidgetRef ref,
    DiningTable table,
  ) async {
    // The backend refuses while an order is open. Saying so before they confirm
    // is kinder than letting the request fail.
    final blocked = table.parties.isNotEmpty || !table.isFree;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Delete ${table.name}?'),
        content: Text(
          blocked
              ? 'Someone is seated here. Settle or cancel the order first.'
              : 'Past bills keep their own record, so history is not affected.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: blocked ? null : () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(tableAdminRepositoryProvider).deleteTable(table.id);
      _refresh(ref);
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  /// A free table starts an order. An occupied one asks which party is meant,
  /// including the option of a new one.
  ///
  /// The picker is shown for one party as well as for several. Opening the only
  /// party's order directly reads like a shortcut, but it left no way to seat a
  /// second party at all: the option to start one lives in this dialog, and the
  /// dialog only appeared once two parties already existed — which nothing
  /// could bring about.
  Future<void> _openTable(BuildContext context, WidgetRef ref, DiningTable table) async {
    if (!table.needsPartyChoice) {
      await _startOrder(context, ref, table);
      return;
    }

    final choice = await showDialog<_PartyChoice>(
      context: context,
      builder: (_) => _PartyPicker(table: table),
    );
    if (choice == null || !context.mounted) return;

    if (choice.newParty) {
      await _startOrder(context, ref, table);
    } else {
      await _openOrder(context, ref, choice.orderId!);
    }
  }

  Future<void> _startOrder(BuildContext context, WidgetRef ref, DiningTable table) async {
    // Only ask for a label when the table already holds someone — otherwise it
    // is a question with an obvious answer, asked during a rush.
    final seatLabel = table.parties.isEmpty
        ? null
        : await showDialog<String>(
            context: context,
            builder: (_) => _SeatLabelDialog(tableName: table.name),
          );
    if (!context.mounted) return;

    try {
      final order = await ref
          .read(orderRepositoryProvider)
          .startDineIn(table.id, seatLabel: seatLabel);
      if (!context.mounted) return;
      await _openOrder(context, ref, order.id);
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    }
  }

  Future<void> _openOrder(BuildContext context, WidgetRef ref, String orderId) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => OrderScreen(orderId: orderId)),
    );
    // The floor changes whenever an order opens, closes or is billed.
    ref.invalidate(floorProvider);
  }
}

/// Section name, with a live count of what is seated.
class _SectionHeader extends StatelessWidget {
  const _SectionHeader({
    required this.section,
    required this.onRename,
    required this.onDelete,
    required this.onMove,
    required this.canMoveUp,
    required this.canMoveDown,
  });

  final FloorSection section;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  /// -1 to move a step up the floor, 1 to move down.
  final void Function(int direction) onMove;

  final bool canMoveUp;
  final bool canMoveDown;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final free = section.tables.where((t) => t.isFree).length;
    final total = section.tables.length;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(section.name.toUpperCase(), style: theme.textTheme.labelSmall),
        const SizedBox(width: AppSpacing.md),
        Expanded(child: Container(height: 1, color: AppColors.border)),
        const SizedBox(width: AppSpacing.md),
        Text(
          total == 0 ? 'no tables' : '$free of $total free',
          style: theme.textTheme.bodySmall,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_horiz, size: 18),
          tooltip: 'Section setup',
          onSelected: (value) {
            if (value == 'rename') onRename();
            if (value == 'delete') onDelete();
            if (value == 'up') onMove(-1);
            if (value == 'down') onMove(1);
          },
          itemBuilder: (_) => [
            // Moved a step at a time rather than dragged: the sections are
            // stacked around grids of tables, and a drag across them is easy
            // to drop in the wrong place.
            if (canMoveUp)
              const PopupMenuItem(value: 'up', child: Text('Move up')),
            if (canMoveDown)
              const PopupMenuItem(value: 'down', child: Text('Move down')),
            const PopupMenuItem(value: 'rename', child: Text('Rename section')),
            const PopupMenuItem(value: 'delete', child: Text('Delete section')),
          ],
        ),
      ],
    );
  }
}

class _EmptyFloor extends StatelessWidget {
  const _EmptyFloor({required this.onAddSection});

  final VoidCallback onAddSection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 340),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.table_restaurant_outlined,
              size: AppSpacing.xxl,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('No tables yet', style: theme.textTheme.titleLarge),
            const SizedBox(height: AppSpacing.xs),
            Text(
              'Start with a section — AC Hall, Terrace — then add its tables.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: AppSpacing.lg),
            ElevatedButton.icon(
              onPressed: onAddSection,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('New section'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PartyChoice {
  const _PartyChoice.existing(this.orderId) : newParty = false;
  const _PartyChoice.fresh()
      : orderId = null,
        newParty = true;

  final String? orderId;
  final bool newParty;
}

/// Shown whenever a table already holds anyone.
///
/// Including a single party: this dialog is the only route to seating another,
/// so skipping it for one made a second party impossible to create.
class _PartyPicker extends StatelessWidget {
  const _PartyPicker({required this.table});

  final DiningTable table;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('${table.name} · who is this for?'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final party in table.parties)
              ListTile(
                contentPadding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
                leading: const Icon(Icons.receipt_long_outlined),
                title: Text(party.label),
                // Only when the label adds something. An unlabelled party's
                // label is already "#7", and repeating it as "Order #7"
                // underneath said the same thing twice.
                subtitle: party.seatLabel == null ? null : Text('Order #${party.orderNo}'),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
                ),
                onTap: () => Navigator.of(context).pop(_PartyChoice.existing(party.orderId)),
              ),
            const Divider(height: AppSpacing.lg),

            // Filled, not tinted text. The accent yellow reads at 1.6:1 against
            // this dialog's surface — well under the 4.5:1 text needs — so as a
            // label it was nearly invisible, and the one action that seats a
            // second party looked like disabled help text. On the fill it
            // carries dark ink at 10:1 and reads as the button it is.
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: () => Navigator.of(context).pop(const _PartyChoice.fresh()),
                icon: const Icon(Icons.add),
                label: const Text('Seat another party'),
              ),
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

/// Labels a second party sharing a table, so the kitchen and the till can tell
/// them apart.
class _SeatLabelDialog extends StatefulWidget {
  const _SeatLabelDialog({required this.tableName});

  final String tableName;

  @override
  State<_SeatLabelDialog> createState() => _SeatLabelDialogState();
}

class _SeatLabelDialogState extends State<_SeatLabelDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text('Second party at ${widget.tableName}'),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'A label keeps the two bills apart on screen and on the kitchen ticket.',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: AppSpacing.md),
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Label',
                hintText: 'B, Window, Corner',
              ),
              onSubmitted: (value) => Navigator.of(context).pop(value),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Skip'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Start order'),
        ),
      ],
    );
  }
}
