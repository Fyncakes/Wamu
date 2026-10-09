class CategoryModel {
  const CategoryModel({
    required this.id,
    required this.name,
    this.slug,
    this.icon,
    this.imageUrl,
  });

  factory CategoryModel.fromJson(Map<String, dynamic> json) {
    return CategoryModel(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      slug: json['slug']?.toString(),
      icon: json['icon']?.toString(),
      imageUrl: json['icon_url']?.toString() ?? json['image_url']?.toString(),
    );
  }

  final String id;
  final String name;
  final String? slug;
  final String? icon;
  final String? imageUrl;
}
