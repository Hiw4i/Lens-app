import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_provider.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// On/off switch for the global haptic-feedback setting.
///
/// API: watches [hapticsEnabledProvider] (`true` = On, `false` = Off) and
/// writes back through [HapticsEnabledNotifier.setEnabled]. Two options only:
/// the stored setting is a bool, so an Off/Light/Full intensity scale would
/// need a prefs migration plus a scope change — out of scope for this switch.
/// Styled as a pill ([BorderRadius.circular(32)]) with the accent fill for the
/// selected segment and the surface fill otherwise, so it sits naturally in
/// the Lens settings; an [AppHaptics.selection] tick confirms the change.
class HapticsSelector extends ConsumerWidget {
  const HapticsSelector({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(hapticsEnabledProvider);
    final colors = context.themeColors;
    return SegmentedButton<bool>(
      segments: const [
        ButtonSegment(value: true, label: Text('On')),
        ButtonSegment(value: false, label: Text('Off')),
      ],
      selected: {enabled},
      showSelectedIcon: false,
      onSelectionChanged: (selected) {
        AppHaptics.selection();
        ref.read(hapticsEnabledProvider.notifier).setEnabled(selected.first);
      },
      style: SegmentedButton.styleFrom(
        foregroundColor: colors.secondary,
        selectedForegroundColor: colors.primaryInverse,
        selectedBackgroundColor: colors.accent,
        backgroundColor: colors.surface,
        side: BorderSide(color: colors.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      ),
    );
  }
}
