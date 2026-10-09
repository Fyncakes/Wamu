/// Formats amounts in Ugandan Shillings (UGX).
String formatUgx(num amount) {
  final value = amount.round();
  final str = value.toString();
  final buffer = StringBuffer();
  for (var i = 0; i < str.length; i++) {
    if (i > 0 && (str.length - i) % 3 == 0) {
      buffer.write(',');
    }
    buffer.write(str[i]);
  }
  return 'UGX ${buffer.toString()}';
}
