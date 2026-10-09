/// User model mapped from FastAPI UserResponse (+ nested profile).
class UserModel {
  const UserModel({
    required this.id,
    required this.phone,
    this.firstName,
    this.lastName,
    this.email,
    this.avatarUrl,
    this.bio,
    this.role = 'CUSTOMER',
    this.showLastSeen = true,
    this.showOnline = true,
    this.showReadReceipts = true,
    this.wantsToBuy = true,
    this.ownsBusiness = false,
    this.wantsToRide = false,
  });

  factory UserModel.fromJson(Map<String, dynamic> json) {
    final profile = json['profile'] as Map<String, dynamic>?;
    final first = profile?['first_name']?.toString() ?? json['first_name']?.toString();
    final last = profile?['last_name']?.toString() ?? json['last_name']?.toString();
    final legacyName = json['name']?.toString();
    return UserModel(
      id: json['id']?.toString() ?? '',
      phone: json['phone']?.toString() ?? '',
      firstName: first ?? (legacyName != null ? legacyName.split(' ').first : null),
      lastName: last ??
          (legacyName != null && legacyName.contains(' ')
              ? legacyName.split(' ').skip(1).join(' ')
              : null),
      email: json['email']?.toString() ?? profile?['email']?.toString(),
      avatarUrl: profile?['avatar_url']?.toString() ?? json['avatar_url']?.toString(),
      bio: profile?['bio']?.toString() ?? json['bio']?.toString(),
      role: json['role']?.toString() ?? 'CUSTOMER',
      showLastSeen: profile?['show_last_seen'] != false,
      showOnline: profile?['show_online'] != false,
      showReadReceipts: profile?['show_read_receipts'] != false,
      wantsToBuy: profile?['wants_to_buy'] != false,
      ownsBusiness: profile?['owns_business'] == true,
      wantsToRide: profile?['wants_to_ride'] == true,
    );
  }

  final String id;
  final String phone;
  final String? firstName;
  final String? lastName;
  final String? email;
  final String? avatarUrl;
  final String? bio;
  final String role;
  final bool showLastSeen;
  final bool showOnline;
  final bool showReadReceipts;
  final bool wantsToBuy;
  final bool ownsBusiness;
  final bool wantsToRide;

  String get name {
    final parts = [firstName, lastName].whereType<String>().where((s) => s.trim().isNotEmpty);
    return parts.join(' ');
  }

  bool get needsProfileSetup => name.trim().isEmpty;
  bool get isBusinessOwner => ownsBusiness || role == 'BUSINESS';
  bool get isAdmin => role.toUpperCase() == 'ADMIN';

  Map<String, dynamic> toJson() => {
        'id': id,
        'phone': phone,
        'first_name': firstName,
        'last_name': lastName,
        'email': email,
        'avatar_url': avatarUrl,
        'role': role,
      };
}
