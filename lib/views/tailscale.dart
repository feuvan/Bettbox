import 'package:bett_box/clash/clash.dart';
import 'package:bett_box/common/common.dart';
import 'package:bett_box/models/models.dart';
import 'package:bett_box/providers/providers.dart';
import 'package:bett_box/state.dart';
import 'package:bett_box/views/config/network.dart';
import 'package:bett_box/widgets/widgets.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Saves [builder]'s result; re-applies the profile when the running node
/// (the active network, if enabled) changed.
void _update(
  WidgetRef ref,
  TailscaleProps Function(TailscaleProps state) builder,
) {
  final prev = ref.read(tailscaleSettingProvider);
  final next = builder(prev);
  if (next == prev) return;
  ref.read(tailscaleSettingProvider.notifier).value = next;
  if (prev.runningNetwork == next.runningNetwork) return;
  if (prev.runningNetwork?.id != next.runningNetwork?.id) {
    // Another node: its login state is unknown until it reports.
    ref.read(tailscaleAuthUrlProvider.notifier).value = null;
  }
  globalState.appController.applyProfileDebounce(silence: true);
  if (!listEquals(prev.tunRouteCidrs, next.tunRouteCidrs)) {
    showVpnRestartTip(ref);
  }
}

void _updateNetwork(
  WidgetRef ref,
  String id,
  TailscaleNetwork Function(TailscaleNetwork network) builder,
) {
  _update(
    ref,
    (state) => state.copyWith(
      networks: [
        for (final network in state.networks)
          network.id == id ? builder(network) : network,
      ],
    ),
  );
}

/// Has the core delete the network's node identity, then re-applies.
Future<void> _resetNode(WidgetRef ref, TailscaleNetwork network) async {
  globalState.resetTailscaleDirs.add(network.stateDir);
  if (ref.read(tailscaleSettingProvider).runningNetwork?.id == network.id) {
    ref.read(tailscaleAuthUrlProvider.notifier).value = null;
  }
  await globalState.appController.applyProfile(silence: true);
}

String? _notEmpty(String? value) => value == null || value.trim().isEmpty
    ? appLocalizations.emptyTip(appLocalizations.name)
    : null;

class TailscaleView extends ConsumerWidget {
  const TailscaleView({super.key});

  Future<void> _addNetwork(WidgetRef ref) async {
    final label = await globalState.showCommonDialog<String>(
      child: InputDialog(
        title: appLocalizations.tailscaleAddNetwork,
        labelText: appLocalizations.name,
        value: '',
        validator: _notEmpty,
      ),
    );
    if (label == null || label.trim().isEmpty) return;
    final network = TailscaleNetwork(id: utils.id, label: label.trim());
    _update(
      ref,
      (state) => state.copyWith(
        // Pin the current active network so adding one never switches.
        activeId: state.activeNetwork?.id ?? network.id,
        networks: [...state.networks, network],
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final props = ref.watch(tailscaleSettingProvider);
    final active = props.activeNetwork;
    final authUrl = ref.watch(tailscaleAuthUrlProvider);

    return generateListView([
      ...generateSection(
        items: [
          ListItem.switchItem(
            title: Text(appLocalizations.tailscaleEnable),
            subtitle: Text(appLocalizations.tailscaleEnableDesc),
            delegate: SwitchDelegate(
              value: props.enable,
              onChanged: active == null
                  ? null
                  : (value) =>
                        _update(ref, (state) => state.copyWith(enable: value)),
            ),
          ),
          if (active != null)
            ListItem<String>.options(
              title: Text(appLocalizations.tailscaleNetwork),
              subtitle: Text(active.label),
              delegate: OptionsDelegate<String>(
                title: appLocalizations.tailscaleNetwork,
                options: [for (final network in props.networks) network.id],
                textBuilder: (id) =>
                    props.networks.firstWhere((n) => n.id == id).label,
                value: active.id,
                onChanged: (id) {
                  if (id == null) return;
                  _update(ref, (state) => state.copyWith(activeId: id));
                },
              ),
            ),
          if (props.enable && active != null)
            ListItem(
              title: Text(appLocalizations.tailscaleLogin),
              subtitle: Text(switch (authUrl) {
                null => appLocalizations.tailscaleLoginDesc,
                '' => appLocalizations.tailscaleLoggedIn,
                final url => url,
              }),
              onTap: () {
                if (authUrl != null && authUrl.isNotEmpty) {
                  globalState.openUrl(authUrl);
                } else {
                  globalState.showNotifier(appLocalizations.tailscaleStarting);
                }
                // Any dial starts the node (no-op if running); a new login
                // URL arrives as a tailscaleAuth message
                // (ClashManager.onTailscaleAuth).
                final name = globalState.tailscaleName;
                if (name == null) return;
                clashCore
                    .getDelay(ref.read(appSettingProvider).testUrl, name)
                    .ignore();
              },
            ),
        ],
      ),
      ...generateSection(
        title: appLocalizations.tailscaleNetworks,
        items: [
          for (final network in props.networks)
            ListItem.next(
              title: Text(network.label),
              subtitle: Text(
                network.controlUrl.isEmpty
                    ? 'tailscale.com'
                    : network.controlUrl,
              ),
              delegate: NextDelegate(
                title: network.label,
                builder: (_) => TailscaleNetworkView(id: network.id),
              ),
            ),
          ListItem(
            leading: const Icon(Icons.add),
            title: Text(appLocalizations.tailscaleAddNetwork),
            onTap: () => _addNetwork(ref),
          ),
        ],
      ),
    ]);
  }
}

class TailscaleNetworkView extends ConsumerWidget {
  final String id;

  const TailscaleNetworkView({super.key, required this.id});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final network = ref.watch(
      tailscaleSettingProvider.select(
        (state) => state.networks.where((n) => n.id == id).firstOrNull,
      ),
    );
    if (network == null) return const SizedBox.shrink();

    Widget input({
      required String title,
      required String value,
      required String subtitle,
      required TailscaleNetwork Function(TailscaleNetwork network, String value)
      onChanged,
      String? hintText,
      bool obscureText = false,
      FormFieldValidator<String>? validator,
    }) {
      return ListItem.input(
        title: Text(title),
        subtitle: Text(subtitle),
        delegate: InputDelegate(
          title: title,
          value: value,
          hintText: hintText,
          obscureText: obscureText,
          validator: validator,
          onChanged: (String? value) {
            if (value == null) return;
            _updateNetwork(
              ref,
              id,
              (network) => onChanged(network, value.trim()),
            );
          },
        ),
      );
    }

    Widget toggle({
      required String title,
      required String subtitle,
      required bool value,
      required TailscaleNetwork Function(TailscaleNetwork network, bool value)
      onChanged,
    }) {
      return ListItem.switchItem(
        title: Text(title),
        subtitle: Text(subtitle),
        delegate: SwitchDelegate(
          value: value,
          onChanged: (bool value) =>
              _updateNetwork(ref, id, (network) => onChanged(network, value)),
        ),
      );
    }

    final items = [
      input(
        title: appLocalizations.name,
        value: network.label,
        subtitle: network.label,
        validator: _notEmpty,
        onChanged: (network, value) => network.copyWith(label: value),
      ),
      input(
        title: appLocalizations.tailscaleAuthKey,
        value: network.authKey,
        subtitle: network.authKey.isEmpty
            ? appLocalizations.tailscaleAuthKeyDesc
            : '••••••••',
        hintText: 'tskey-auth-…',
        obscureText: true,
        onChanged: (network, value) => network.copyWith(authKey: value),
      ),
      input(
        title: appLocalizations.tailscaleHostname,
        value: network.hostname,
        subtitle: network.hostname.isEmpty ? 'bettbox' : network.hostname,
        hintText: 'bettbox',
        onChanged: (network, value) => network.copyWith(hostname: value),
      ),
      input(
        title: appLocalizations.tailscaleControlUrl,
        value: network.controlUrl,
        subtitle: network.controlUrl.isEmpty
            ? appLocalizations.tailscaleControlUrlDesc
            : network.controlUrl,
        hintText: 'https://headscale.example.com',
        validator: (value) {
          final url = value?.trim() ?? '';
          if (url.isEmpty || url.isHttpUrl) return null;
          return appLocalizations.urlTip(appLocalizations.tailscaleControlUrl);
        },
        onChanged: (network, value) => network.copyWith(controlUrl: value),
      ),
      input(
        title: appLocalizations.tailscaleExitNode,
        value: network.exitNode,
        subtitle: network.exitNode.isEmpty
            ? appLocalizations.tailscaleExitNodeDesc
            : network.exitNode,
        hintText: 'auto:any',
        onChanged: (network, value) => network.copyWith(exitNode: value),
      ),
      if (network.exitNode.isNotEmpty)
        toggle(
          title: appLocalizations.tailscaleExitNodeLan,
          subtitle: appLocalizations.tailscaleExitNodeLanDesc,
          value: network.exitNodeAllowLanAccess,
          onChanged: (network, value) =>
              network.copyWith(exitNodeAllowLanAccess: value),
        ),
      toggle(
        title: appLocalizations.tailscaleAcceptRoutes,
        subtitle: appLocalizations.tailscaleAcceptRoutesDesc,
        value: network.acceptRoutes,
        onChanged: (network, value) => network.copyWith(acceptRoutes: value),
      ),
      toggle(
        title: appLocalizations.tailscaleUdp,
        subtitle: appLocalizations.tailscaleUdpDesc,
        value: network.udp,
        onChanged: (network, value) => network.copyWith(udp: value),
      ),
      _EntriesItem(
        id: id,
        title: appLocalizations.tailscaleRoutes,
        subtitle: appLocalizations.tailscaleRoutesDesc,
        read: (network) => network.routes,
        write: (network, items) => network.copyWith(routes: items),
        defaults: defaultTailscaleRoutes,
        validator: (value) => isValidTailscaleEntry(value ?? '')
            ? null
            : appLocalizations.tailscaleInvalidEntry,
      ),
      _EntriesItem(
        id: id,
        title: appLocalizations.tailscaleDns,
        subtitle: appLocalizations.tailscaleDnsDesc,
        read: (network) => network.dns,
        write: (network, items) => network.copyWith(dns: items),
        validator: (value) => parseTailscaleDns(value ?? '') != null
            ? null
            : appLocalizations.tailscaleInvalidDns,
      ),
      ListItem(
        title: Text(appLocalizations.tailscaleReset),
        subtitle: Text(appLocalizations.tailscaleResetDesc),
        onTap: () async {
          final res = await globalState.showMessage(
            title: appLocalizations.tailscaleReset,
            message: TextSpan(text: appLocalizations.resetTip),
          );
          if (res == true) await _resetNode(ref, network);
        },
      ),
      ListItem(
        title: Text(appLocalizations.tailscaleDeleteNetwork),
        onTap: () async {
          final res = await globalState.showMessage(
            message: TextSpan(text: appLocalizations.deleteTip(network.label)),
          );
          if (res != true) return;
          _update(ref, (state) {
            // Never switch tailnets implicitly: deleting the active one
            // turns Tailscale off until the user picks another.
            final wasActive = state.activeNetwork?.id == id;
            return state.copyWith(
              networks: state.networks.where((n) => n.id != id).toList(),
              enable: state.enable && !wasActive,
              activeId: wasActive ? null : state.activeId,
            );
          });
          if (context.mounted) Navigator.of(context).pop();
          await _resetNode(ref, network);
        },
      ),
    ];

    return generateListView(generateSection(items: items));
  }
}

/// A network's list setting edited with [ListInputPage].
class _EntriesItem extends StatelessWidget {
  final String id;
  final String title;
  final String subtitle;
  final List<String> Function(TailscaleNetwork network) read;
  final TailscaleNetwork Function(TailscaleNetwork network, List<String> items)
  write;
  final List<String>? defaults;
  final FormFieldValidator<String> validator;

  const _EntriesItem({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.read,
    required this.write,
    required this.validator,
    this.defaults,
  });

  @override
  Widget build(BuildContext context) {
    return ListItem.next(
      title: Text(title),
      subtitle: Text(subtitle),
      delegate: NextDelegate(
        blur: false,
        title: title,
        actions: [
          if (defaults case final defaults?)
            Consumer(
              builder: (_, ref, _) => IconButton(
                onPressed: () async {
                  final res = await globalState.showMessage(
                    title: appLocalizations.reset,
                    message: TextSpan(text: appLocalizations.resetTip),
                  );
                  if (res != true) return;
                  _updateNetwork(
                    ref,
                    id,
                    (network) => write(network, defaults),
                  );
                },
                tooltip: appLocalizations.reset,
                icon: const Icon(Icons.replay),
              ),
            ),
        ],
        widget: Consumer(
          builder: (_, ref, _) {
            final items = ref.watch(
              tailscaleSettingProvider.select(
                (state) => [
                  for (final network in state.networks)
                    if (network.id == id) ...read(network),
                ],
              ),
            );
            return ListInputPage(
              title: title,
              items: items,
              titleBuilder: (item) => Text(item),
              validator: validator,
              onChange: (items) => _updateNetwork(
                ref,
                id,
                (network) => write(network, List.from(items)),
              ),
            );
          },
        ),
      ),
    );
  }
}
