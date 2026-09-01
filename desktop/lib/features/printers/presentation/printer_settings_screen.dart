import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/api_exception.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/app_loading.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/printer_repository.dart';
import 'printer_dialog.dart';
import 'printer_scan_dialog.dart';

final _printersProvider = FutureProvider<List<Printer>>((ref) {
  return ref.watch(printerRepositoryProvider).printers();
});

/// Printer setup.
///
/// Scanning is offered alongside manual entry because most people do not know
/// their printer's IP, and the ones who do can still type it.
class PrinterSettingsScreen extends ConsumerWidget {
  const PrinterSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final printers = ref.watch(_printersProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Printers')),
      body: printers.when(
        loading: () => const AppLoading(message: 'Loading printers'),
        error: (error, _) => Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Padding(
              padding: const EdgeInsets.all(AppSpacing.xl),
              child: ErrorBanner(message: '$error'),
            ),
          ),
        ),
        data: (list) => ListView(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.lg,
            AppSpacing.xxl,
          ),
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Thermal printers on USB or the network. One printer set to '
                    '"Both" covers a counter with a single machine.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SizedBox(width: AppSpacing.md),
                // Scanning is the path most people should take, so it sits beside
                // the manual option rather than behind it.
                OutlinedButton.icon(
                  onPressed: () => _scan(context, ref),
                  icon: const Icon(Icons.wifi_find_outlined, size: 18),
                  label: const Text('Scan'),
                ),
                const SizedBox(width: AppSpacing.sm),
                ElevatedButton.icon(
                  onPressed: () => _add(context, ref),
                  icon: const Icon(Icons.add, size: 18),
                  label: const Text('Add manually'),
                ),
              ],
            ),
            const SizedBox(height: AppSpacing.lg),

            if (list.isEmpty)
              _NoPrinters(
                onScan: () => _scan(context, ref),
                onAdd: () => _add(context, ref),
              )
            else
              for (final printer in list) ...[
                _PrinterCard(
                  printer: printer,
                  onEdit: () => _edit(context, ref, printer),
                  onTest: () => _test(context, ref, printer),
                  onToggle: (active) => _toggle(context, ref, printer, active),
                  onDelete: () => _delete(context, ref, printer),
                ),
                const SizedBox(height: AppSpacing.sm),
              ],
          ],
        ),
      ),
    );
  }

  /// Scans, then opens the editor prefilled with whatever was picked.
  Future<void> _scan(BuildContext context, WidgetRef ref) async {
    final found = await PrinterScanDialog.show(context);
    if (found == null || !context.mounted) return;

    if (await PrinterDialog.show(context, discovered: found) == true) {
      _refresh(ref);
    }
  }

  void _refresh(WidgetRef ref) {
    ref.invalidate(_printersProvider);
    // The order screen hides its KOT button on this, so it must not go stale.
    ref.invalidate(printerStatusProvider);
  }

  Future<void> _add(BuildContext context, WidgetRef ref) async {
    if (await PrinterDialog.show(context) == true) _refresh(ref);
  }

  Future<void> _edit(
    BuildContext context,
    WidgetRef ref,
    Printer printer,
  ) async {
    if (await PrinterDialog.show(context, printer: printer) == true) {
      _refresh(ref);
    }
  }

  /// Sends a test page and reports what happened.
  ///
  /// Waits for the result rather than queueing quietly: the whole point is
  /// finding out whether the printer works.
  Future<void> _test(
    BuildContext context,
    WidgetRef ref,
    Printer printer,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Sending a test page to ${printer.name}...')),
    );

    try {
      final result = await ref.read(printerRepositoryProvider).test(printer.id);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            result.printed
                ? 'Test page sent to ${printer.name}'
                : result.error ?? 'The printer did not respond',
          ),
          duration: const Duration(seconds: 6),
        ),
      );
    } on ApiException catch (error) {
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _toggle(
    BuildContext context,
    WidgetRef ref,
    Printer printer,
    bool active,
  ) async {
    try {
      await ref
          .read(printerRepositoryProvider)
          .update(printer.id, isActive: active);
      _refresh(ref);
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _delete(
    BuildContext context,
    WidgetRef ref,
    Printer printer,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Remove ${printer.name}?'),
        content: const Text(
          'Anything routed to it will have nowhere to print. To stop using it '
          'for now, switch it off instead.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(printerRepositoryProvider).delete(printer.id);
      _refresh(ref);
    } on ApiException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _PrinterCard extends StatelessWidget {
  const _PrinterCard({
    required this.printer,
    required this.onEdit,
    required this.onTest,
    required this.onToggle,
    required this.onDelete,
  });

  final Printer printer;
  final VoidCallback onEdit;
  final VoidCallback onTest;
  final ValueChanged<bool> onToggle;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final off = !printer.isActive;

    return Container(
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.border),
      ),
      padding: const EdgeInsets.all(AppSpacing.md),
      child: Row(
        children: [
          Icon(
            printer.connection == 'network' ? Icons.lan_outlined : Icons.usb,
            size: 20,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: AppSpacing.md),

          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  printer.name,
                  style: theme.textTheme.bodyLarge?.copyWith(
                    color: off ? theme.colorScheme.onSurfaceVariant : null,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${printer.address}  ·  ${_roleLabel(printer.role)}  ·  ${printer.paperWidth}',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),

          TextButton.icon(
            onPressed: printer.isActive ? onTest : null,
            icon: const Icon(Icons.print_outlined, size: 18),
            label: const Text('Test'),
          ),
          const SizedBox(width: AppSpacing.sm),

          Switch(value: printer.isActive, onChanged: onToggle),

          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz, size: 18),
            tooltip: 'Printer actions',
            onSelected: (value) {
              if (value == 'edit') onEdit();
              if (value == 'delete') onDelete();
            },
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('Edit')),
              PopupMenuItem(value: 'delete', child: Text('Remove')),
            ],
          ),
        ],
      ),
    );
  }

  static String _roleLabel(String role) => switch (role) {
    'bill' => 'Bills',
    'kot' => 'Kitchen',
    _ => 'Bills and kitchen',
  };
}

class _NoPrinters extends StatelessWidget {
  const _NoPrinters({required this.onScan, required this.onAdd});

  final VoidCallback onScan;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(AppSpacing.radiusMd),
        border: Border.all(color: AppColors.borderStrong),
      ),
      padding: const EdgeInsets.all(AppSpacing.xl),
      child: Column(
        children: [
          Icon(
            Icons.print_disabled_outlined,
            size: AppSpacing.xl,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(height: AppSpacing.md),
          Text('No printers yet', style: theme.textTheme.titleLarge),
          const SizedBox(height: AppSpacing.xs),
          Text(
            // Says plainly what still works without one, so nobody thinks
            // billing is blocked.
            'Orders and bills still work without a printer — nothing prints, '
            'that is all.',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: AppSpacing.lg),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              ElevatedButton.icon(
                onPressed: onScan,
                icon: const Icon(Icons.wifi_find_outlined, size: 18),
                label: const Text('Scan for printers'),
              ),
              const SizedBox(width: AppSpacing.sm),
              OutlinedButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add manually'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
