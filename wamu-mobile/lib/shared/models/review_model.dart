import '../utils/json_numbers.dart';

class ReviewModel {
  const ReviewModel({
    required this.id,
    required this.rating,
    this.comment,
    this.reply,
    this.userId,
  });

  factory ReviewModel.fromJson(Map<String, dynamic> json) {
    return ReviewModel(
      id: json['id']?.toString() ?? '',
      rating: parseIntOrZero(json['rating']),
      comment: json['comment']?.toString(),
      reply: json['reply']?.toString(),
      userId: json['user_id']?.toString(),
    );
  }

  final String id;
  final int rating;
  final String? comment;
  final String? reply;
  final String? userId;
}
