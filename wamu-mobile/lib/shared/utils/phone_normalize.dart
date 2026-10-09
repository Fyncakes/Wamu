/// Normalizes Ugandan phone numbers to E.164 (+256...) format.
String normalizeUgPhone(String input) {
  var digits = input.replaceAll(RegExp(r'\D'), '');
  if (digits.startsWith('256')) {
    digits = digits.substring(3);
  } else if (digits.startsWith('0')) {
    digits = digits.substring(1);
  }
  if (digits.length != 9) {
    throw FormatException('Phone must be 9 digits after country code');
  }
  return '+256$digits';
}

/// Validates a normalized or raw Ugandan phone string.
bool isValidUgPhone(String input) {
  try {
    normalizeUgPhone(input);
    return true;
  } catch (_) {
    return false;
  }
}
