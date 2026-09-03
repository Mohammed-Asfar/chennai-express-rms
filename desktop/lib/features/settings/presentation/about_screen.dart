import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/api/providers.dart';
import '../../../core/theme/app_spacing.dart';

/// What this application is, which version is running, and who to contact.
///
/// The version matters for support: "which build are you on" is the first
/// question worth asking about any reported fault, and until now there was
/// nowhere on screen that answered it.
class AboutScreen extends ConsumerWidget {
  const AboutScreen({super.key});

  static const developerName = 'Mohammed Asfar';
  static const developerUrl = 'https://mohammed-asfar.devsyndicate.in/';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final version = ref.watch(appVersionProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(
        padding: const EdgeInsets.all(AppSpacing.lg),
        children: [
          Text('Chennai Express', style: theme.textTheme.headlineSmall),
          const SizedBox(height: AppSpacing.xs),
          Text(
            'Restaurant billing and management',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),

          const SizedBox(height: AppSpacing.lg),

          // Asked for by support before anything else, so it is plain text that
          // can be read down a phone line rather than an icon to interpret.
          version.when(
            loading: () => const _Detail(label: 'Version', value: 'Checking…'),
            error: (_, _) => const _Detail(label: 'Version', value: 'Unknown'),
            data: (info) => _Detail(
              label: 'Version',
              value: '${info.version}  (build ${info.buildNumber})',
            ),
          ),

          const Divider(height: AppSpacing.xl),

          Text('Developed by', style: theme.textTheme.titleSmall),
          const SizedBox(height: AppSpacing.sm),
          Text(developerName, style: theme.textTheme.titleMedium),
          const SizedBox(height: AppSpacing.xs),

          // Selectable rather than a launcher: url_launcher is not a dependency,
          // and adding a plugin so a till can open a browser it should not be
          // opening is the wrong trade. Someone reading this wants to type it
          // into their phone, and a long-press copies it.
          const _CopyableUrl(url: developerUrl),
        ],
      ),
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(child: SelectableText(value, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}

/// The developer's address, with a tap to copy.
class _CopyableUrl extends StatelessWidget {
  const _CopyableUrl({required this.url});

  final String url;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return InkWell(
      onTap: () async {
        await Clipboard.setData(ClipboardData(text: url));
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Address copied')),
        );
      },
      borderRadius: BorderRadius.circular(AppSpacing.xs),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AppSpacing.xs),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                url,
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ),
            const SizedBox(width: AppSpacing.sm),
            Icon(
              Icons.copy_outlined,
              size: 16,
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ],
        ),
      ),
    );
  }
}

/// The running version, read from the backend.
///
/// The backend owns this: it is the half that is bundled and updated, and
/// duplicating the number in Dart is how the two drift apart. `/version` is
/// unauthenticated, so this screen works before anyone signs in.
final appVersionProvider = FutureProvider<AppVersion>((ref) async {
  final json = await ref.watch(apiClientProvider).get('/version');
  return AppVersion(
    version: json['version'] as String,
    buildNumber: json['buildNumber'] as int,
  );
});

class AppVersion {
  const AppVersion({required this.version, required this.buildNumber});
  final String version;
  final int buildNumber;
}
