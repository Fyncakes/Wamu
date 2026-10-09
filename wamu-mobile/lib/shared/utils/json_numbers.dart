/// Safe JSON number parsing — FastAPI Decimal fields often arrive as strings
/// (e.g. `"4.80"`) especially with SQLite/JSON serialization.
double? parseDouble(dynamic value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? parseInt(dynamic value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value) ?? double.tryParse(value)?.toInt();
  return null;
}

double parseDoubleOrZero(dynamic value) => parseDouble(value) ?? 0;
int parseIntOrZero(dynamic value) => parseInt(value) ?? 0;
