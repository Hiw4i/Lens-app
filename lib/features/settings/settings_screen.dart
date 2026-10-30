import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_provider.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_policy.dart';
import 'package:lens/shared/motion/policy/ui_performance_provider.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/app_tokens.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/theme/theme_provider.dart';
import 'package:lens/shared/widgets/animation/pressable_scale.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';
import 'package:lens/shared/widgets/inputs/app_choice_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Customisation: appearance, motion quality and haptics.
///
/// Every control writes straight to a Riverpod notifier, so the change is
/// visible while the finger is still on the screen. The screen deliberately
/// stays scrollable and avoids fixed-height rows so Dynamic Type can grow it.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final colors = context.themeColors;
    final brightness = ref.watch(themeBrightnessProvider);
    final palette = ref.watch(paletteProvider);
    final hapticsOn = ref.watch(hapticsEnabledProvider);
    final profile = ref.watch(uiPerformanceProfileProvider);
    final speed = ref.watch(animationSpeedProvider);

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
              child: Row(
                children: [
                  AppButton.iconGhost(
                    icon: LucideIcons.arrowLeft,
                    tooltip: 'Back',
                    onTap: () => Navigator.of(context).maybePop(),
                    style: AppButtonStyle(foregroundColor: colors.primary),
                  ),
                  Expanded(
                    child: Text(
                      'Settings',
                      textAlign: TextAlign.center,
                      style: AppTextStyles.subheading(context),
                    ),
                  ),
                  const SizedBox(width: 40),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
                children: [
                  _Section(
                    title: 'Appearance',
                    children: [
                      _Setting(
                        label: 'Brightness',
                        description: 'Follow the system or choose a mode.',
                        child: _ChoiceGroup<ThemeBrightness>(
                          values: ThemeBrightness.values,
                          selected: brightness,
                          labelOf: (value) => value.label,
                          onSelected: (value) => ref
                              .read(themeBrightnessProvider.notifier)
                              .setBrightness(value),
                        ),
                      ),
                      _Setting(
                        label: 'Palette',
                        description: 'The colour family used across Lens.',
                        child: _ChoiceGroup<int>(
                          values: List<int>.generate(
                            palettes.length,
                            (index) => index,
                          ),
                          selected: palette,
                          labelOf: (index) => palettes[index].name,
                          onSelected: (index) => ref
                              .read(paletteProvider.notifier)
                              .setPalette(index),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Motion',
                    children: [
                      _Setting(
                        label: 'Graphics quality',
                        description:
                            'Performance removes blur and non-essential motion. '
                            'Cinematic keeps the full glass and motion treatment.',
                        child: _ChoiceGroup<UiPerformanceProfile>(
                          values: UiPerformanceProfile.values,
                          selected: profile,
                          labelOf: (value) => value.label,
                          onSelected: (value) => ref
                              .read(uiPerformanceProfileProvider.notifier)
                              .setProfile(value),
                        ),
                      ),
                      _Setting(
                        label: 'Animation speed',
                        description: 'Balanced stretches policy-driven transitions by 25%.',
                        child: _ChoiceGroup<AnimationSpeed>(
                          values: AnimationSpeed.values,
                          selected: speed,
                          labelOf: (value) => value.label,
                          onSelected: (value) => ref
                              .read(animationSpeedProvider.notifier)
                              .setSpeed(value),
                        ),
                      ),
                    ],
                  ),
                  _Section(
                    title: 'Feedback',
                    children: [
                      _ToggleSetting(
                        label: 'Haptic feedback',
                        description:
                            'A light tick on selections, sliders and buttons.',
                        value: hapticsOn,
                        onChanged: (next) {
                          if (next && context.hapticsEnabled) {
                            AppHaptics.selection();
                          }
                          ref
                              .read(hapticsEnabledProvider.notifier)
                              .setEnabled(next);
                        },
                      ),
                    ],
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 4, left: 4),
                    child: Text(
                      'Lens · 1.0',
                      style: AppTextStyles.smallDim(context).copyWith(
                        fontFamily: 'JetBrainsMono',
                        letterSpacing: 0.4,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.children});

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(left: 4, bottom: 8),
            child: Text(
              title.toUpperCase(),
              style: AppTextStyles.smallDim(context).copyWith(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 1.3,
              ),
            ),
          ),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: colors.surface,
              borderRadius: BorderRadius.circular(AppRadius.lg),
              border: Border.all(color: colors.border),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (var i = 0; i < children.length; i++) ...[
                  if (i > 0)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      child: Divider(height: 1, color: colors.border),
                    ),
                  children[i],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Setting extends StatelessWidget {
  const _Setting({
    required this.label,
    required this.description,
    required this.child,
  });

  final String label;
  final String description;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          label,
          style: AppTextStyles.body(context)
              .copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 2),
        Text(description, style: AppTextStyles.smallDim(context)),
        const SizedBox(height: 12),
        child,
      ],
    );
  }
}

class _ToggleSetting extends StatelessWidget {
  const _ToggleSetting({
    required this.label,
    required this.description,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String description;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: AppTextStyles.body(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(description, style: AppTextStyles.smallDim(context)),
            ],
          ),
        ),
        const SizedBox(width: 16),
        _Toggle(value: value, onChanged: onChanged),
      ],
    );
  }
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 160),
    );
    void toggle() => onChanged(!value);
    return Semantics(
      toggled: value,
      button: true,
      label: 'Haptic feedback',
      onTap: toggle,
      child: ExcludeSemantics(
        child: PressableScale(
          onTap: toggle,
          child: AnimatedContainer(
            duration: duration,
            width: 50,
            height: 30,
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: value ? colors.primary : colors.surfaceBright,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: colors.border),
            ),
            child: AnimatedAlign(
              duration: duration,
              curve: Curves.easeOutCubic,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: value ? colors.primaryInverse : colors.secondary,
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChoiceGroup<T> extends StatelessWidget {
  const _ChoiceGroup({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelected,
  });

  final List<T> values;
  final T selected;
  final String Function(T value) labelOf;
  final ValueChanged<T> onSelected;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final value in values)
          _Choice(
            label: labelOf(value),
            selected: value == selected,
            onTap: value == selected ? null : () => onSelected(value),
          ),
      ],
    );
  }
}

class _Choice extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return AppChoiceChip(label: label, selected: selected, onTap: onTap);
  }
}
