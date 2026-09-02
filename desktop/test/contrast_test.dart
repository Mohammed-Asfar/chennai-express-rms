import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:chennai_express_pos/core/theme/app_colors.dart';

/// Guards text against the background it is actually drawn on.
///
/// The sidebar badge shipped using [AppColors.danger], which is mixed for a
/// light ground: on the charcoal spine it measured 2.23:1, so the one warning
/// telling someone their sales are not backed up was harder to read than the
/// text around it. Nothing caught it — the theme test forbids stray colour
/// literals but says nothing about whether a legal colour is legible.
///
/// Ratios are WCAG 2.1: 4.5:1 for body text, 3:1 for large or bold text and
/// for icons carrying meaning.
double _relativeLuminance(Color color) {
  double channel(double c) =>
      c <= 0.03928 ? c / 12.92 : math.pow((c + 0.055) / 1.055, 2.4).toDouble();

  return 0.2126 * channel(color.r) +
      0.7152 * channel(color.g) +
      0.0722 * channel(color.b);
}

double contrast(Color a, Color b) {
  final la = _relativeLuminance(a);
  final lb = _relativeLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

void main() {
  group('the charcoal sidebar', () {
    // Both grounds a badge can sit on: the spine itself and the raised fill.
    const grounds = {'shell': AppColors.shell, 'shellHover': AppColors.shellHover};

    test('the stopped-backup colour is readable on the sidebar', () {
      grounds.forEach((name, ground) {
        final ratio = contrast(AppColors.dangerOnShell, ground);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: 'dangerOnShell on $name is ${ratio.toStringAsFixed(2)}:1',
        );
      });
    });

    test('the behind-backup colour is readable on the sidebar', () {
      grounds.forEach((name, ground) {
        final ratio = contrast(AppColors.warningOnShell, ground);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: 'warningOnShell on $name is ${ratio.toStringAsFixed(2)}:1',
        );
      });
    });

    test('the synced colour is readable on the sidebar', () {
      grounds.forEach((name, ground) {
        final ratio = contrast(AppColors.successOnShell, ground);
        expect(
          ratio,
          greaterThanOrEqualTo(4.5),
          reason: 'successOnShell on $name is ${ratio.toStringAsFixed(2)}:1',
        );
      });
    });

    test('the light-ground status colours are still unusable here', () {
      // Not a wish, a fact worth pinning: if someone later "simplifies" the
      // badge back to AppColors.danger, this says why that was wrong.
      expect(
        contrast(AppColors.danger, AppColors.shellHover),
        lessThan(4.5),
        reason: 'danger is mixed for a light ground and must not be used on the shell',
      );
      // The one that prompted successOnShell: at 2.28:1 the "synced" state
      // would have been the least legible thing in the sidebar.
      expect(
        contrast(AppColors.success, AppColors.shellHover),
        lessThan(4.5),
        reason: 'success is mixed for a light ground and must not be used on the shell',
      );
    });

    test('ordinary sidebar text is readable', () {
      expect(
        contrast(AppColors.onShell, AppColors.shell),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('muted sidebar text clears the large-text bar', () {
      // Used for secondary lines and the chevron. Held to 3:1 rather than 4.5,
      // which is the standard's allowance for non-body text — and stated here
      // so the weaker bar is a decision rather than an oversight.
      expect(
        contrast(AppColors.onShellMuted, AppColors.shell),
        greaterThanOrEqualTo(3.0),
      );
    });
  });

  group('status colours on the light working area', () {
    test('danger is readable on the canvas and on its own tint', () {
      expect(
        contrast(AppColors.danger, AppColors.canvas),
        greaterThanOrEqualTo(4.5),
      );
      expect(
        contrast(AppColors.danger, AppColors.dangerTint),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('warning is readable on its own tint', () {
      // The bookings "Late" pill and the sync verdict both rely on this pair.
      expect(
        contrast(AppColors.warning, AppColors.warningTint),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('success is readable on its own tint', () {
      expect(
        contrast(AppColors.success, AppColors.successTint),
        greaterThanOrEqualTo(4.5),
      );
    });

    test('body text is readable on every surface', () {
      for (final surface in [
        AppColors.canvas,
        AppColors.surface,
        AppColors.surfaceSunken,
      ]) {
        expect(contrast(AppColors.ink, surface), greaterThanOrEqualTo(4.5));
      }
    });

    test('muted body text is readable on the surfaces it is used on', () {
      for (final surface in [AppColors.surface, AppColors.surfaceSunken]) {
        expect(
          contrast(AppColors.inkMuted, surface),
          greaterThanOrEqualTo(4.5),
        );
      }
    });

    test('text on the amber accent is readable', () {
      // The primary button and the active nav item.
      expect(
        contrast(AppColors.onAccent, AppColors.accent),
        greaterThanOrEqualTo(4.5),
      );
    });
  });
}
