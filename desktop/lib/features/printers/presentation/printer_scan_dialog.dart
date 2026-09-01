import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/error_banner.dart';
import '../data/printer_repository.dart';

/// Scans for printers and lets one be picked.
///
/// Results stream in rather than appearing all at once: USB printers land in
/// under a second, so the list is already useful while the network sweep runs.
/// Returns the chosen printer, for the editor to prefill.
class PrinterScanDialog extends ConsumerStatefulWidget {
  const PrinterScanDialog({super.key});

  static Future<DiscoveredPrinter?> show(BuildContext context) {
    return showDialog<DiscoveredPrinter>(
      context: context,
      builder: (_) => const PrinterScanDialog(),
    );
  }

  @override
  ConsumerState<PrinterScanDialog> createState() => _PrinterScanDialogState();
}

class _PrinterScanDialogState extends ConsumerState<PrinterScanDialog> {
  StreamSubscription<DiscoveryEvent>? _subscription;
  final List<DiscoveredPrinter> _found = [];

  double _progress = 0;
  bool _scanning = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _start();
  }

  @override
  void dispose() {
    // Closing the socket stops the sweep server-side, so a cancelled dialog
    // does not leave 500 probes running for nobody.
    _subscription?.cancel();
    super.dispose();
  }

  void _start() {
    setState(() {
      _found.clear();
      _progress = 0;
      _scanning = true;
      _error = null;
    });

    _subscription?.cancel();
    _subscription = ref
        .read(printerRepositoryProvider)
        .discoverStream()
        .listen(
          (event) {
            if (!mounted) return;
            setState(() {
              switch (event) {
                case DiscoveryFound(:final printer):
                  _found.add(printer);
                case DiscoveryProgress(:final fraction):
                  _progress = fraction;
                case DiscoveryDone():
                  _scanning = false;
                  _progress = 1;
                case DiscoveryFailed(:final message):
                  _error = message;
                  _scanning = false;
              }
            });
          },
          onError: (Object error) {
            if (!mounted) return;
            setState(() {
              _error = '$error';
              _scanning = false;
            });
          },
          onDone: () {
            if (!mounted) return;
            setState(() => _scanning = false);
          },
        );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: const Text('Find a printer'),
      content: SizedBox(
        width: 460,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null) ...[
              ErrorBanner(message: _error!),
              const SizedBox(height: AppSpacing.md),
            ],

            Row(
              children: [
                Expanded(
                  child: Text(
                    _scanning
                        ? 'Looking on this PC and the network...'
                        : _found.isEmpty
                        ? 'Nothing found'
                        : '${_found.length} found',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (!_scanning)
                  TextButton.icon(
                    onPressed: _start,
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Scan again'),
                  ),
              ],
            ),
            const SizedBox(height: AppSpacing.sm),

            // Determinate, because a sweep has a known size — a spinner would
            // leave you wondering whether it had stalled.
            if (_scanning)
              LinearProgressIndicator(value: _progress == 0 ? null : _progress)
            else
              const SizedBox(height: 4),

            const SizedBox(height: AppSpacing.md),

            Expanded(
              child: _found.isEmpty
                  ? _EmptyResult(scanning: _scanning)
                  : ListView.builder(
                      itemCount: _found.length,
                      itemBuilder: (context, index) => _ResultTile(
                        printer: _found[index],
                        onTap: () => Navigator.of(context).pop(_found[index]),
                      ),
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _ResultTile extends StatelessWidget {
  const _ResultTile({required this.printer, required this.onTap});

  final DiscoveredPrinter printer;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final added = printer.alreadyAdded;

    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: added ? AppColors.surfaceSunken : AppColors.surface,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: InkWell(
          // An already-configured printer is shown so it is clear the scan saw
          // it, but picking it again would just create a duplicate.
          onTap: added ? null : onTap,
          borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              border: Border.all(color: AppColors.border),
            ),
            padding: const EdgeInsets.all(AppSpacing.md),
            child: Row(
              children: [
                Icon(
                  printer.connection == 'network'
                      ? Icons.lan_outlined
                      : Icons.usb,
                  size: 20,
                  color: theme.colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: AppSpacing.md),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              printer.name,
                              style: theme.textTheme.bodyLarge,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (printer.likelyThermal) ...[
                            const SizedBox(width: AppSpacing.sm),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AppSpacing.sm,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: AppColors.accentTint,
                                borderRadius: BorderRadius.circular(
                                  AppSpacing.radiusSm,
                                ),
                              ),
                              child: Text(
                                'RECEIPT',
                                style: theme.textTheme.labelSmall,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          printer.address,
                          printer.detail,
                        ].whereType<String>().join('  ·  '),
                        style: theme.textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
                if (added)
                  Text('Added', style: theme.textTheme.bodySmall)
                else
                  const Icon(Icons.chevron_right, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _EmptyResult extends StatelessWidget {
  const _EmptyResult({required this.scanning});

  final bool scanning;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (scanning) return const SizedBox.shrink();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(AppSpacing.lg),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off,
              size: AppSpacing.xl,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: AppSpacing.md),
            Text('No printers found', style: theme.textTheme.titleMedium),
            const SizedBox(height: AppSpacing.xs),
            Text(
              // The two things that actually go wrong, rather than a generic
              // "check your connection".
              'A USB printer needs its Windows driver installed. A network '
              'printer must be switched on and on this same network.',
              style: theme.textTheme.bodySmall,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
