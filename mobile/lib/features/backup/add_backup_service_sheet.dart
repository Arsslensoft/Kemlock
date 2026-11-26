import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../i18n/messages.dart';
import '../../models/custom_field.dart';
import '../../ui/ui.dart';
import '../../vault/vault_controller.dart';
import '../fields/custom_fields_editor.dart';
import '../sync/kemlock/km_kinds.dart' show KmKind;
import 'backup_codes.dart';
import 'code_import_button.dart';
import 'code_readers.dart';

/// Adds a service's backup codes, `AddBackupServiceDialog.tsx`: the
/// service, filled in with [initialName] when the coverage card asks for
/// one, and the codes, pasted or read from a file.
Future<void> showAddBackupServiceSheet(BuildContext context, {String initialName = ''}) => showAppBottomSheet<void>(
  context,
  label: context.t('addBackup.title'),
  builder: (_) => AddBackupServiceSheet(initialName: initialName),
);

/// The sheet [showAddBackupServiceSheet] opens. Saving adds the service
/// through the vault controller, which says so in a toast, and closes it.
class AddBackupServiceSheet extends ConsumerStatefulWidget {
  const AddBackupServiceSheet({super.key, this.initialName = ''});

  final String initialName;

  @override
  ConsumerState<AddBackupServiceSheet> createState() => _AddBackupServiceSheetState();
}

class _AddBackupServiceSheetState extends ConsumerState<AddBackupServiceSheet> {
  late final _name = TextEditingController(text: widget.initialName);
  final _codes = TextEditingController();

  /// The custom fields, as the editor last gave them.
  var _fields = <CustomField>[];

  /// Text recognition misreads now and then, so its codes get a reminder to check them.
  bool _imported = false;

  @override
  void dispose() {
    _name.dispose();
    _codes.dispose();
    super.dispose();
  }

  void _addImported(List<String> codes) {
    _codes.text = [_codes.text.trim(), ...codes].where((part) => part.isNotEmpty).join('\n');
    setState(() => _imported = true);
  }

  void _save(List<String> parsed) {
    final name = _name.text.trim();
    if (name.isEmpty || parsed.isEmpty) return;
    unawaited(ref.read(vaultControllerProvider.notifier).addBackupService(name, parsed, fields: _fields));
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final b = context.bmc;
    final parsed = parseCodes(_codes.text);
    final canSave = _name.text.trim().isNotEmpty && parsed.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DialogHeading(icon: const Icon(Icons.confirmation_number_outlined), title: context.t('addBackup.title')),
        Flexible(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(context.t('addBackup.body'), style: AppType.body2.copyWith(color: p.textSecondary)),
                const SizedBox(height: 18),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _name,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  textInputAction: TextInputAction.next,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    labelText: context.t('addBackup.field.serviceName'),
                    hintText: context.t('addBackup.field.serviceNamePlaceholder'),
                  ),
                ),
                const SizedBox(height: 16),
                TextField(
                  enableIMEPersonalizedLearning: false,
                  controller: _codes,
                  minLines: 5,
                  maxLines: 12,
                  keyboardType: TextInputType.multiline,
                  autocorrect: false,
                  enableSuggestions: false,
                  onChanged: (_) => setState(() {}),
                  style: AppType.mono(fontSize: 13, color: p.text),
                  decoration: InputDecoration(
                    labelText: context.t('addBackup.field.codes'),
                    hintText: context.t('addBackup.field.codesPlaceholder'),
                    hintMaxLines: 4,
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                CodeImportButton(onCodes: _addImported),
                // Only text recognition and PDFium make the mistakes this warns of
                if (_imported && (ref.watch(readsPicturesProvider) || ref.watch(readsPdfsProvider))) ...[
                  const SizedBox(height: 16),
                  AppAlert(severity: AlertSeverity.info, child: Text(context.t('codeImport.check'))),
                ],
                if (parsed.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  FadeIn(
                    duration: const Duration(milliseconds: 300),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          context.t('addBackup.detected', {'count': parsed.length}),
                          style: AppType.caption.copyWith(color: p.textSecondary),
                        ),
                        const SizedBox(height: 8),
                        Wrap(
                          spacing: 6,
                          runSpacing: 6,
                          children: [
                            for (final code in parsed)
                              PopIn(
                                key: ValueKey(code),
                                duration: const Duration(milliseconds: 350),
                                child: Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                                  decoration: BoxDecoration(color: b.raised, borderRadius: BorderRadius.circular(10)),
                                  child: Text(code, style: AppType.mono(fontSize: 12, color: p.text)),
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
                if (_codes.text.trim().isNotEmpty && parsed.isEmpty) ...[
                  const SizedBox(height: 16),
                  AppAlert(severity: AlertSeverity.warning, child: Text(context.t('addBackup.noDetected'))),
                ],
                const SizedBox(height: 16),
                CustomFieldsEditor(kind: KmKind.backupCodes, fields: _fields, onChanged: (next) => _fields = next),
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Wrap(
            alignment: WrapAlignment.end,
            spacing: 10,
            runSpacing: 8,
            children: [
              TextButton(
                style: TextButton.styleFrom(foregroundColor: p.text),
                onPressed: () => Navigator.of(context).maybePop(),
                child: Text(context.t('addBackup.cancel')),
              ),
              FilledButton(
                onPressed: canSave ? () => _save(parsed) : null,
                child: Text(context.t('addBackup.save', {'count': parsed.length})),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
