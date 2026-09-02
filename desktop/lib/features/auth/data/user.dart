enum UserRole { admin, cashier }

class User {
  const User({
    required this.id,
    required this.username,
    required this.fullName,
    required this.role,
    required this.isActive,
    required this.mustChangePassword,
  });

  final String id;
  final String username;
  final String fullName;
  final UserRole role;
  final bool isActive;
  final bool mustChangePassword;

  bool get isAdmin => role == UserRole.admin;

  factory User.fromJson(Map<String, dynamic> json) => User(
        id: json['id'] as String,
        username: json['username'] as String,
        fullName: json['fullName'] as String,
        role: json['role'] == 'admin' ? UserRole.admin : UserRole.cashier,
        isActive: json['isActive'] as bool? ?? true,
        mustChangePassword: json['mustChangePassword'] as bool? ?? false,
      );
}
