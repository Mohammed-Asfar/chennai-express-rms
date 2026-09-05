import 'package:flutter/material.dart';
import '../../../core/api/api_exception.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_spacing.dart';
import '../../../core/widgets/error_banner.dart';
import '../../floor/data/floor_models.dart';
import '../../floor/data/floor_repository.dart';
import '../data/booking_models.dart';
import '../data/booking_repository.dart';

/// Takes a booking, or edits one that has not been seated yet.
///
/// The table picker is the substance of this dialog. A booking may hold several
/// tables — a party of 12 across three is one booking — so tables are chips
/// that toggle, not a dropdown that permits only one.
class BookingEditorDialog extends ConsumerStatefulWidget {
  const BookingEditorDialog({super.key, this.existing, this.date});

  /// Null when taking a new booking.
  final Booking? existing;

  /// The day being booked into. Ignored when editing.
  final DateTime? date;

  /// Resolves to the warnings raised, or null if it was dismissed. An empty
  /// list means saved with nothing to flag.
  static Future<List<String>?> show(
    BuildContext context, {
    Booking? existing,
    DateTime? date,
  }) {
    return showDialog<List<String>>(
      context: context,
      builder: (_) => BookingEditorDialog(existing: existing, date: date),
    );
  }

  @override
  ConsumerState<BookingEditorDialog> createState() => _BookingEditorDialogState();
}

class _BookingEditorDialogState extends ConsumerState<BookingEditorDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.customerName ?? '',
  );
  late final TextEditingController _phone = TextEditingController(
    text: widget.existing?.customerPhone ?? '',
  );
  late final TextEditingController _partySize = TextEditingController(
    text: (widget.existing?.partySize ?? 2).toString(),
  );
  late final TextEditingController _notes = TextEditingController(
    text: widget.existing?.notes ?? '',
  );

  late TimeOfDay _time = widget.existing != null
      ? TimeOfDay.fromDateTime(widget.existing!.reservedAt)
      // The next half hour: most bookings taken over the phone are for later
      // today, and a time already in the past is never the answer.
      : _nextHalfHour();

  late final Set<String> _tableIds = {
    ...?widget.existing?.tables.map((t) => t.id),
  };

  bool _busy = false;
  String? _error;

  /// The next half hour on the clock — 7:10 gives 7:30, 7:40 gives 8:00.
  static TimeOfDay _nextHalfHour() {
    final now = DateTime.now();
    final rounded = DateTime(
      now.year,
      now.month,
      now.day,
      now.hour,
      now.minute < 30 ? 30 : 60,
    );
    return TimeOfDay.fromDateTime(rounded);
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    _partySize.dispose();
    _notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final floor = ref.watch(floorProvider);
    final editing = widget.existing != null;

    return AlertDialog(
      title: Text(editing ? 'Edit booking' : 'New booking'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: TextField(
                      controller: _name,
                      enabled: !_busy,
                      autofocus: true,
                      textCapitalization: TextCapitalization.words,
                      decoration: const InputDecoration(
                        labelText: 'Name',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: TextField(
                      controller: _phone,
                      enabled: !_busy,
                      keyboardType: TextInputType.phone,
                      decoration: const InputDecoration(
                        labelText: 'Phone',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: AppSpacing.md),
              Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _partySize,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      onChanged: (_) => setState(() {}),
                      decoration: const InputDecoration(
                        labelText: 'Guests',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: AppSpacing.sm),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _busy ? null : _pickTime,
                      icon: const Icon(Icons.schedule, size: 18),
                      label: Text(_time.format(context)),
                    ),
                  ),
                ],
              ),

              const SizedBox(height: AppSpacing.lg),
              Text('Tables', style: theme.textTheme.titleSmall),
              const SizedBox(height: AppSpacing.xs),
              Text(
                'Pick as many as the party needs — this stays one booking.',
                style: theme.textTheme.bodySmall,
              ),
              const SizedBox(height: AppSpacing.sm),

              floor.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(AppSpacing.md),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (error, _) => ErrorBanner(message: userMessage(error)),
                data: (sections) => _TablePicker(
                  sections: sections,
                  selected: _tableIds,
                  // A table the booking already holds stays pickable even if it
                  // is occupied right now — the party sitting there will have
                  // left by the time this booking arrives.
                  alreadyHeld: {...?widget.existing?.tables.map((t) => t.id)},
                  enabled: !_busy,
                  onToggle: (id) => setState(() {
                    if (!_tableIds.remove(id)) _tableIds.add(id);
                  }),
                ),
              ),

              if (_seatShortfall > 0) ...[
                const SizedBox(height: AppSpacing.sm),
                _Note(
                  icon: Icons.info_outline,
                  message:
                      'Those tables seat $_selectedSeats. The party is $_partyCount.',
                ),
              ],

              const SizedBox(height: AppSpacing.md),
              TextField(
                controller: _notes,
                enabled: !_busy,
                maxLength: 200,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'Window seat, birthday, high chair',
                  isDense: true,
                ),
              ),

              if (_error != null) ...[
                const SizedBox(height: AppSpacing.sm),
                ErrorBanner(message: _error!),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _busy ? null : _submit,
          child: Text(editing ? 'Save' : 'Book'),
        ),
      ],
    );
  }

  int get _partyCount => int.tryParse(_partySize.text.trim()) ?? 0;

  int get _selectedSeats {
    final sections = ref.read(floorProvider).valueOrNull ?? const <FloorSection>[];
    var total = 0;
    for (final section in sections) {
      for (final table in section.tables) {
        if (_tableIds.contains(table.id)) total += table.seats;
      }
    }
    return total;
  }

  int get _seatShortfall =>
      _selectedSeats == 0 ? 0 : (_partyCount - _selectedSeats).clamp(0, 999);

  Future<void> _pickTime() async {
    final picked = await showTimePicker(context: context, initialTime: _time);
    if (picked != null) setState(() => _time = picked);
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty) {
      setState(() => _error = 'Whose booking is it?');
      return;
    }

    final party = _partyCount;
    if (party <= 0) {
      setState(() => _error = 'How many are coming?');
      return;
    }

    if (_tableIds.isEmpty) {
      setState(() => _error = 'Pick at least one table.');
      return;
    }

    // The booking's own day when editing: moving the time must not silently
    // move the booking to today.
    final day = widget.existing?.reservedAt ?? widget.date ?? DateTime.now();
    final reservedAt = DateTime(
      day.year,
      day.month,
      day.day,
      _time.hour,
      _time.minute,
    );

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final repository = ref.read(bookingRepositoryProvider);
      final result = widget.existing == null
          ? await repository.create(
              customerName: name,
              customerPhone: _phone.text.trim(),
              partySize: party,
              reservedAt: reservedAt,
              tableIds: _tableIds.toList(),
              notes: _notes.text.trim(),
            )
          : await repository.update(
              widget.existing!.id,
              customerName: name,
              customerPhone: _phone.text.trim(),
              partySize: party,
              reservedAt: reservedAt,
              tableIds: _tableIds.toList(),
              notes: _notes.text.trim(),
            );

      // Booking a table changes what the floor shows, so it must be refetched.
      ref.invalidate(floorProvider);
      if (mounted) Navigator.of(context).pop(result.warnings);
    } catch (error) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = userMessage(error);
        });
      }
    }
  }
}

/// Every table on the floor, grouped by section, as toggles.
class _TablePicker extends StatelessWidget {
  const _TablePicker({
    required this.sections,
    required this.selected,
    required this.alreadyHeld,
    required this.enabled,
    required this.onToggle,
  });

  final List<FloorSection> sections;
  final Set<String> selected;
  final Set<String> alreadyHeld;
  final bool enabled;
  final ValueChanged<String> onToggle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: AppColors.surfaceSunken,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      ),
      padding: const EdgeInsets.all(AppSpacing.sm),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final section in sections) ...[
              Padding(
                padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
                child: Text(section.name, style: theme.textTheme.labelMedium),
              ),
              Wrap(
                spacing: AppSpacing.sm,
                runSpacing: AppSpacing.sm,
                children: [
                  for (final table in section.tables)
                    _TableChip(
                      table: table,
                      selected: selected.contains(table.id),
                      held: alreadyHeld.contains(table.id),
                      enabled: enabled,
                      onTap: () => onToggle(table.id),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _TableChip extends StatelessWidget {
  const _TableChip({
    required this.table,
    required this.selected,
    required this.held,
    required this.enabled,
    required this.onTap,
  });

  final DiningTable table;
  final bool selected;
  final bool held;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Occupied and reserved are shown, never disabled. A table busy now will be
    // free this evening, and refusing to book it would be wrong more often than
    // right — the floor knows its own turnover better than the app does.
    final busy = table.status != TableStatus.free && !held;

    return Material(
      color: selected ? AppColors.accent : AppColors.surface,
      borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.md,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
            border: Border.all(
              color: selected ? AppColors.accent : AppColors.border,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                table.name,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: selected ? AppColors.onAccent : AppColors.ink,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                ),
              ),
              Text(
                busy ? '${table.seats} seats · busy' : '${table.seats} seats',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected ? AppColors.onAccent : AppColors.inkMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Note extends StatelessWidget {
  const _Note({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: AppColors.warning),
        const SizedBox(width: AppSpacing.sm),
        Expanded(
          child: Text(
            message,
            style: theme.textTheme.bodySmall?.copyWith(color: AppColors.warning),
          ),
        ),
      ],
    );
  }
}
