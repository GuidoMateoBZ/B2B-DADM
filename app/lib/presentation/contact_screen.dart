import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/models/mesh_contact.dart';
import '../providers/contact_provider.dart';
import '../providers/node_id_provider.dart';
import '../services/local_notification_service.dart';
import 'contact_form_dialog.dart';

const contactsRouteName = '/contacts';

class ContactScreen extends StatelessWidget {
  const ContactScreen({super.key});

  Future<void> _addContact(BuildContext context, String? myNodeId) async {
    final result = await showDialog<ContactFormResult>(
      context: context,
      builder: (_) => ContactFormDialog(myNodeId: myNodeId),
    );
    if (result == null || !context.mounted) return;

    try {
      final inserted = await context.read<ContactProvider>().addContact(
        result.nodeId,
        result.alias,
      );
      if (context.mounted) {
        _showMessage(
          context,
          inserted ? 'Contacto guardado' : 'Ese Node ID ya está en contactos',
        );
      }
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'No se pudo guardar el contacto: $error');
      }
    }
  }

  Future<void> _editContact(BuildContext context, MeshContact contact) async {
    final result = await showDialog<ContactFormResult>(
      context: context,
      builder: (_) => ContactFormDialog(
        myNodeId: context.read<NodeIdProvider>().nodeId,
        existingNodeId: contact.nodeId,
        initialAlias: contact.alias,
      ),
    );
    if (result == null || !context.mounted) return;

    try {
      await context.read<ContactProvider>().updateAlias(
        contact.nodeId,
        result.alias,
      );
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'No se pudo actualizar el contacto: $error');
      }
    }
  }

  Future<void> _removeContact(BuildContext context, MeshContact contact) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Quitar contacto'),
        content: Text(
          '¿Querés quitar a ${contact.displayName} de la agenda? '
          'El historial de chat se conservará.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancelar'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Quitar'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await context.read<ContactProvider>().removeContact(contact.nodeId);
    } catch (error) {
      if (context.mounted) {
        _showMessage(context, 'No se pudo quitar el contacto: $error');
      }
    }
  }

  void _showMessage(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contacts = context.watch<ContactProvider>();
    final myNodeId = context.watch<NodeIdProvider>().nodeId;

    return Scaffold(
      appBar: AppBar(title: const Text('Contactos')),
      body: contacts.isLoading && contacts.contacts.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : contacts.errorMessage != null && contacts.contacts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(contacts.errorMessage!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: contacts.loadContacts,
                      icon: const Icon(Icons.refresh),
                      label: const Text('Reintentar'),
                    ),
                  ],
                ),
              ),
            )
          : contacts.contacts.isEmpty
          ? const _EmptyContacts()
          : ListView.separated(
              padding: const EdgeInsets.only(bottom: 88, top: 8),
              itemCount: contacts.contacts.length,
              separatorBuilder: (_, _) => const Divider(height: 1, indent: 72),
              itemBuilder: (context, index) {
                final contact = contacts.contacts[index];
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: Theme.of(context)
                        .colorScheme
                        .primaryContainer,
                    child: const Icon(Icons.person_outline),
                  ),
                  title: Text(
                    contact.displayName,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    contact.nodeId,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 12,
                    ),
                  ),
                  onTap: () => Navigator.pushNamed(
                    context,
                    chatRouteName,
                    arguments: contact.nodeId,
                  ),
                  trailing: PopupMenuButton<String>(
                    onSelected: (action) {
                      if (action == 'edit') {
                        _editContact(context, contact);
                      } else if (action == 'remove') {
                        _removeContact(context, contact);
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Editar alias')),
                      PopupMenuItem(
                        value: 'remove',
                        child: Text('Quitar de contactos'),
                      ),
                    ],
                  ),
                );
              },
            ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addContact(context, myNodeId),
        icon: const Icon(Icons.person_add_alt_1),
        label: const Text('Agregar contacto'),
      ),
    );
  }
}

class _EmptyContacts extends StatelessWidget {
  const _EmptyContacts();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.contacts_outlined,
              size: 56,
              color: theme.colorScheme.outlineVariant,
            ),
            const SizedBox(height: 12),
            Text(
              'Tu agenda está vacía',
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Agregá un Node ID manualmente o escaneá su QR. '
              'Guardar un contacto no inicia un chat.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
