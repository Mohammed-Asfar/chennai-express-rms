import 'package:flutter/material.dart';
import '../theme/app_colors.dart';
import '../theme/app_spacing.dart';
import '../theme/app_text_styles.dart';

class SidebarItem {
  const SidebarItem({
    required this.icon,
    required this.label,
    this.enabled = true,
  });

  final IconData icon;
  final String label;

  /// False for sections not built yet — visible so staff can see what is
  /// coming, but not clickable.
  final bool enabled;
}

/// The charcoal spine down the left edge.
///
/// It carries the 30% of the palette: a permanent dark anchor that separates
/// navigation from the work area, so the eye always knows where it is. The
/// active item is the only place the accent appears here.
class AppSidebar extends StatelessWidget {
  const AppSidebar({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    this.footer,
  });

  final List<SidebarItem> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final Widget? footer;

  static const double width = 248;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: AppColors.shell,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _Wordmark(),
          const SizedBox(height: AppSpacing.sm),

          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm),
              itemCount: items.length,
              itemBuilder: (context, index) => _NavItem(
                item: items[index],
                selected: index == selectedIndex,
                onTap: () => onSelect(index),
              ),
            ),
          ),

          if (footer != null) ...[
            Container(height: 1, color: AppColors.shellBorder),
            footer!,
          ],
        ],
      ),
    );
  }
}

class _Wordmark extends StatelessWidget {
  const _Wordmark();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.lg,
        AppSpacing.md,
      ),
      child: Row(
        children: [
          // Small: the logo is a detailed illustration and shrinking it much
          // further turns the lettering to mush. At 36px it reads as a mark
          // rather than a picture, which is what a permanent sidebar needs.
          Image.asset(
            'assets/logo.png',
            width: 36,
            height: 36,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.medium,
          ),
          const SizedBox(width: AppSpacing.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Chennai Express',
                  style: AppTextStyles.titleMedium.copyWith(color: AppColors.onShell),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  'Restaurant management system',
                  style: AppTextStyles.bodySmall.copyWith(color: AppColors.onShellMuted),
                  // The sidebar is a fixed 248px and this line is long enough
                  // to reach it. Wrapping to two lines is fine; overflowing the
                  // pane is not.
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _NavItem extends StatefulWidget {
  const _NavItem({
    required this.item,
    required this.selected,
    required this.onTap,
  });

  final SidebarItem item;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final selected = widget.selected;

    final foreground = selected
        ? AppColors.onAccent
        : item.enabled
            ? AppColors.onShell
            : AppColors.onShellMuted;

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        cursor: item.enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accent
                : _hovered && item.enabled
                    ? AppColors.shellHover
                    : null,
            borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
          ),
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: item.enabled ? widget.onTap : null,
              borderRadius: BorderRadius.circular(AppSpacing.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: AppSpacing.md,
                  vertical: 11,
                ),
                child: Row(
                  children: [
                    Icon(item.icon, size: 18, color: foreground),
                    const SizedBox(width: AppSpacing.md),
                    Expanded(
                      child: Text(
                        item.label,
                        style: AppTextStyles.bodyMedium.copyWith(
                          color: foreground,
                          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (!item.enabled)
                      Text(
                        'Soon',
                        style: AppTextStyles.bodySmall.copyWith(
                          color: AppColors.onShellMuted,
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
