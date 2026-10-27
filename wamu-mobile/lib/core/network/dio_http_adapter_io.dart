import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';

/// Bind Dio to dart:io so [HttpOverrides.global] (Railway DNS fallback) applies.
void configureWamuDioAdapter(Dio dio) {
  dio.httpClientAdapter = IOHttpClientAdapter(
    createHttpClient: () => HttpClient(),
  );
}
