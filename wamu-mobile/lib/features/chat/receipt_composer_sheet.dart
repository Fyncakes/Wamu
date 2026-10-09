import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/app_theme.dart';
import '../../shared/models/product_model.dart';
import '../../shared/utils/ugx_formatter.dart';

class ReceiptLineDraft {
  ReceiptLineDraft({
    required this.product,
    this.quantity = 1,
    double? unitPrice,
    String? name,
  })  : unitPrice = unitPrice ?? product.price,
        name = name ?? product.name;

  final ProductModel product;
  int quantity;
  double unitPrice;
  String name;

  double get lineTotal => unitPrice * quantity;

  Map<String, dynamic> toApiItem() => {
        'product_id': product.id,
        'quantity': quantity,
        'unit_price': unitPrice,
        'name': name,
      };
}

/// Seller builds / edits a bargained receipt to send (or update) for the buyer.
Future<Map<String, dynamic>?> showReceiptComposer({
  required BuildContext context,
  required List<ProductModel> products,
  String title = 'Create payment receipt',
  String submitLabel = 'Send to buyer',
  List<ReceiptLineDraft>? initialLines,
  String fulfillment = 'PICKUP',
  String? deliveryAddress,
  double? deliveryFee,
  String? note,
}) {
  return showModalBottomSheet<Map<String, dynamic>>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (ctx) => _ReceiptComposerSheet(
      products: products,
      title: title,
      submitLabel: submitLabel,
      initialLines: initialLines ?? const [],
      initialFulfillment: fulfillment,
      initialAddress: deliveryAddress ?? '',
      initialDeliveryFee: deliveryFee,
      initialNote: note ?? '',
    ),
  );
}

class _ReceiptComposerSheet extends StatefulWidget {
  const _ReceiptComposerSheet({
    required this.products,
    required this.title,
    required this.submitLabel,
    required this.initialLines,
    required this.initialFulfillment,
    required this.initialAddress,
    required this.initialDeliveryFee,
    required this.initialNote,
  });

  final List<ProductModel> products;
  final String title;
  final String submitLabel;
  final List<ReceiptLineDraft> initialLines;
  final String initialFulfillment;
  final String initialAddress;
  final double? initialDeliveryFee;
  final String initialNote;

  @override
  State<_ReceiptComposerSheet> createState() => _ReceiptComposerSheetState();
}

class _ReceiptComposerSheetState extends State<_ReceiptComposerSheet> {
  late final List<ReceiptLineDraft> _lines = List.of(widget.initialLines);
  late String _fulfillment = widget.initialFulfillment;
  late final _addressCtrl = TextEditingController(text: widget.initialAddress);
  late final _feeCtrl = TextEditingController(
    text: widget.initialDeliveryFee != null
        ? widget.initialDeliveryFee!.toStringAsFixed(0)
        : (_fulfillment == 'DELIVERY' ? '5000' : '0'),
  );
  late final _noteCtrl = TextEditingController(text: widget.initialNote);

  @override
  void dispose() {
    _addressCtrl.dispose();
    _feeCtrl.dispose();
    _noteCtrl.dispose();
    super.dispose();
  }

  double get _subtotal => _lines.fold(0, (s, l) => s + l.lineTotal);

  double get _fee {
    final parsed = double.tryParse(_feeCtrl.text.trim());
    if (parsed != null) return parsed;
    return _fulfillment == 'DELIVERY' ? 5000 : 0;
  }

  double get _total => _subtotal + _fee;

  Future<void> _addProduct() async {
    final picked = await showModalBottomSheet<ProductModel>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const ListTile(
              title: Text('Add product', style: TextStyle(fontWeight: FontWeight.w700)),
              subtitle: Text('Then edit the agreed price'),
            ),
            ...widget.products.map(
              (p) => ListTile(
                title: Text(p.name),
                subtitle: Text('List ${formatUgx(p.price)}'),
                onTap: () => Navigator.pop(ctx, p),
              ),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    setState(() => _lines.add(ReceiptLineDraft(product: picked)));
  }

  void _submit() {
    if (_lines.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Add at least one item')),
      );
      return;
    }
    if (_fulfillment == 'DELIVERY' && _addressCtrl.text.trim().length < 8) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a delivery address')),
      );
      return;
    }
    Navigator.pop(context, {
      'items': _lines.map((l) => l.toApiItem()).toList(),
      'fulfillment': _fulfillment,
      'delivery_address':
          _fulfillment == 'DELIVERY' ? _addressCtrl.text.trim() : null,
      'delivery_fee': _fee,
      'customer_note': _noteCtrl.text.trim().isEmpty
          ? 'Agreed in chat'
          : _noteCtrl.text.trim(),
    });
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.88,
        child: Column(
          children: [
            ListTile(
              title: Text(widget.title, style: const TextStyle(fontWeight: FontWeight.w800)),
              subtitle: const Text('Set the bargained prices, then send for MoMo payment'),
              trailing: IconButton(
                onPressed: () => Navigator.pop(context),
                icon: const Icon(Icons.close),
              ),
            ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  if (_lines.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Text('No lines yet — add products you agreed on.'),
                    ),
                  ..._lines.asMap().entries.map((e) {
                    final i = e.key;
                    final line = e.value;
                    return Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    line.name,
                                    style: const TextStyle(fontWeight: FontWeight.w700),
                                  ),
                                ),
                                IconButton(
                                  tooltip: 'Remove',
                                  onPressed: () => setState(() => _lines.removeAt(i)),
                                  icon: const Icon(Icons.delete_outline),
                                ),
                              ],
                            ),
                            Text(
                              'Listed ${formatUgx(line.product.price)}',
                              style: TextStyle(fontSize: 12, color: AppTheme.messengerMuted),
                            ),
                            const SizedBox(height: 8),
                            Row(
                              children: [
                                Expanded(
                                  child: TextFormField(
                                    initialValue: line.unitPrice.toStringAsFixed(0),
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                    decoration: const InputDecoration(
                                      labelText: 'Agreed price (UGX)',
                                      isDense: true,
                                    ),
                                    onChanged: (v) {
                                      final n = double.tryParse(v);
                                      if (n != null) setState(() => line.unitPrice = n);
                                    },
                                  ),
                                ),
                                const SizedBox(width: 12),
                                SizedBox(
                                  width: 88,
                                  child: TextFormField(
                                    initialValue: '${line.quantity}',
                                    keyboardType: TextInputType.number,
                                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                                    decoration: const InputDecoration(
                                      labelText: 'Qty',
                                      isDense: true,
                                    ),
                                    onChanged: (v) {
                                      final n = int.tryParse(v);
                                      if (n != null && n > 0) {
                                        setState(() => line.quantity = n);
                                      }
                                    },
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerRight,
                              child: Text(
                                formatUgx(line.lineTotal),
                                style: const TextStyle(fontWeight: FontWeight.w800),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                  OutlinedButton.icon(
                    onPressed: widget.products.isEmpty ? null : _addProduct,
                    icon: const Icon(Icons.add),
                    label: const Text('Add product'),
                  ),
                  const SizedBox(height: 16),
                  Text('Fulfillment', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 8),
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'PICKUP', label: Text('Pickup')),
                      ButtonSegment(value: 'DELIVERY', label: Text('Delivery')),
                    ],
                    selected: {_fulfillment},
                    onSelectionChanged: (s) {
                      setState(() {
                        _fulfillment = s.first;
                        if (_fulfillment == 'PICKUP') {
                          _feeCtrl.text = '0';
                        } else if (_feeCtrl.text.trim() == '0') {
                          _feeCtrl.text = '5000';
                        }
                      });
                    },
                  ),
                  if (_fulfillment == 'DELIVERY') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _addressCtrl,
                      decoration: const InputDecoration(
                        labelText: 'Delivery address',
                        hintText: 'e.g. Ntinda Shopping Centre, Kampala',
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  TextField(
                    controller: _feeCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: 'Delivery / service fee (UGX)',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _noteCtrl,
                    decoration: const InputDecoration(
                      labelText: 'Note on receipt',
                      hintText: 'Agreed after bargaining',
                    ),
                  ),
                  const SizedBox(height: 16),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: AppTheme.accentGreen.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      children: [
                        const Text('Total due', style: TextStyle(fontWeight: FontWeight.w700)),
                        const Spacer(),
                        Text(
                          formatUgx(_total),
                          style: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 18,
                            color: AppTheme.accentGreen,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _submit,
                    style: FilledButton.styleFrom(
                      backgroundColor: AppTheme.accentGreen,
                      foregroundColor: Colors.black,
                    ),
                    child: Text(widget.submitLabel),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
