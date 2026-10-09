import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/network/api_client.dart';

/// AI-powered natural language search via POST /ai/search.
class AiRepository {
  AiRepository(this._client);

  final ApiClient _client;

  Future<Map<String, dynamic>> search(String query) async {
    final response = await _client.post('/ai/search', data: {'query': query});
    return response.data as Map<String, dynamic>;
  }
}

final aiRepositoryProvider = Provider<AiRepository>((ref) {
  return AiRepository(ref.watch(apiClientProvider));
});
