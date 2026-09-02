import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A text field styled entirely by the theme's [InputDecorationTheme].
///
/// Exists so screens do not repeat decoration config — and so they cannot
/// quietly introduce their own colours.
class AppTextField extends StatelessWidget {
  const AppTextField({
    super.key,
    required this.controller,
    required this.label,
    this.focusNode,
    this.obscureText = false,
    this.enabled = true,
    this.autofocus = false,
    this.textInputAction,
    this.onSubmitted,
    this.onChanged,
    this.validator,
    this.suffixIcon,
    this.hintText,
    this.inputFormatters,
  });

  final TextEditingController controller;
  final String label;
  final FocusNode? focusNode;
  final bool obscureText;
  final bool enabled;
  final bool autofocus;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<String>? onChanged;
  final FormFieldValidator<String>? validator;
  final Widget? suffixIcon;
  final String? hintText;

  /// Formatting applied as the user types, e.g. grouping an activation key.
  final List<TextInputFormatter>? inputFormatters;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      focusNode: focusNode,
      obscureText: obscureText,
      enabled: enabled,
      autofocus: autofocus,
      textInputAction: textInputAction,
      onFieldSubmitted: onSubmitted,
      onChanged: onChanged,
      validator: validator,
      inputFormatters: inputFormatters,
      style: Theme.of(context).textTheme.bodyLarge,
      decoration: InputDecoration(
        labelText: label,
        hintText: hintText,
        suffixIcon: suffixIcon,
      ),
    );
  }
}
