import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/bekaa_backdrop.dart';
import '../../data/local/demo_mode.dart';

/// The landing page: a single login, once.
///
/// Two ways in. Against a real deployment, signing in needs the farm
/// network — there is no way to verify a password or issue a token
/// without reaching the server — and that is the app's only online
/// requirement; everything behind it then works offline from the cached
/// session, permissions and farm data.
///
/// The second way exists because there is no deployment yet: this build
/// ships a whole farm inside it, and the demo account opens it with no
/// server at all. That path is advertised on this screen rather than
/// hidden, so nobody is left at a login they cannot get past.
///
/// Either way [SessionController] restores the session at launch, so a
/// worker sees this screen once per install and never again until they
/// sign out.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  late final TextEditingController _serverUrl = TextEditingController(text: context.read<SessionController>().baseUrl);
  bool _showServerField = false;
  bool _obscure = true;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _serverUrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final session = context.read<SessionController>();
    final ok = await session.login(email: _email.text, password: _password.text, serverUrl: _showServerField ? _serverUrl.text : null);
    if (!mounted || ok) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(session.error ?? 'Could not sign in.')));
  }

  /// Fills in the demo account and signs straight in, so nobody has to
  /// find the credentials in a README to open the app.
  Future<void> _useDemo() async {
    _email.text = DemoMode.username;
    _password.text = DemoMode.password;
    await _submit();
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 920),
            child: LayoutBuilder(builder: (context, constraints) {
              final stacked = constraints.maxWidth < kTabletBreakpoint;
              final illustration = ClipRRect(
                borderRadius: FarmRadii.panel,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const BekaaBackdrop(),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [FarmColors.stone.withOpacity(0.15), FarmColors.stone.withOpacity(0.85)],
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(FarmSpacing.lg),
                      child: Align(
                        alignment: Alignment.bottomLeft,
                        child: Text(
                          'Origami Farms — Bekaa Valley, Lebanon',
                          style: FarmTypography.textTheme.bodyMedium?.copyWith(color: FarmColors.ink, fontWeight: FontWeight.w700),
                        ),
                      ),
                    ),
                  ],
                ),
              );
              final form = _LoginForm(
                email: _email,
                password: _password,
                serverUrl: _serverUrl,
                obscure: _obscure,
                showServerField: _showServerField,
                busy: session.busy,
                needsNetwork: session.needsFirstOnlineLogin,
                onUseDemo: _useDemo,
                onToggleObscure: () => setState(() => _obscure = !_obscure),
                onToggleServerField: () => setState(() => _showServerField = !_showServerField),
                onSubmit: _submit,
              );
              if (stacked) {
                return SingleChildScrollView(
                  padding: const EdgeInsets.all(FarmSpacing.lg),
                  child: Column(children: [SizedBox(height: 220, child: illustration), const SizedBox(height: FarmSpacing.lg), form]),
                );
              }
              return Padding(
                padding: const EdgeInsets.all(FarmSpacing.xl),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(flex: 5, child: illustration),
                    const SizedBox(width: FarmSpacing.xl),
                    Expanded(flex: 5, child: Center(child: form)),
                  ],
                ),
              );
            }),
          ),
        ),
      ),
    );
  }
}

class _LoginForm extends StatelessWidget {
  const _LoginForm({
    required this.email,
    required this.password,
    required this.serverUrl,
    required this.obscure,
    required this.showServerField,
    required this.busy,
    required this.needsNetwork,
    required this.onUseDemo,
    required this.onToggleObscure,
    required this.onToggleServerField,
    required this.onSubmit,
  });

  final TextEditingController email;
  final TextEditingController password;
  final TextEditingController serverUrl;
  final bool obscure;
  final bool showServerField;
  final bool busy;

  /// The last attempt couldn't reach the server at all. Say that plainly
  /// — a worker retyping a correct password is the failure mode here.
  final bool needsNetwork;

  final Future<void> Function() onUseDemo;
  final VoidCallback onToggleObscure;
  final VoidCallback onToggleServerField;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.xl),
      decoration: BoxDecoration(color: FarmColors.card, borderRadius: FarmRadii.panel, border: Border.all(color: FarmColors.border), boxShadow: FarmShadows.elevated),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SvgPicture.asset('assets/logo/origami-farmos-mark.svg', width: 36, height: 36),
            const SizedBox(width: 10),
            RichText(
              text: TextSpan(
                style: FarmTypography.textTheme.titleLarge,
                children: const [
                  TextSpan(text: 'Origami ', style: TextStyle(color: FarmColors.cedar)),
                  TextSpan(text: 'FarmOS', style: TextStyle(color: FarmColors.olive)),
                ],
              ),
            ),
          ]),
          const SizedBox(height: FarmSpacing.lg),
          Text(context.t('startMyDay'), style: FarmTypography.display(size: 26)),
          const SizedBox(height: 4),
          Text(context.t('startMyDaySubtitle'), style: FarmTypography.textTheme.bodyMedium),
          if (needsNetwork) ...[
            const SizedBox(height: FarmSpacing.md),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: FarmColors.tint(FarmColors.warning, 0.12),
                border: Border.all(color: FarmColors.warning.withOpacity(0.4)),
                borderRadius: BorderRadius.circular(FarmRadii.sm),
              ),
              child: Row(children: [
                const Icon(Icons.cloud_off, size: 18, color: FarmColors.warning),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    context.t('firstLoginNeedsInternet'),
                    style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.ink),
                  ),
                ),
              ]),
            ),
          ],
          const SizedBox(height: FarmSpacing.lg),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Email'),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: password,
            obscureText: obscure,
            decoration: InputDecoration(
              labelText: 'Password',
              suffixIcon: IconButton(icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined), onPressed: onToggleObscure),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          const SizedBox(height: FarmSpacing.md),
          // This build ships a whole farm on the tablet, so it can be
          // opened and used with no server at all. Saying so beats
          // leaving someone at a login screen they cannot get past.
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: FarmColors.tint(FarmColors.gold, 0.14),
              border: Border.all(color: FarmColors.gold.withOpacity(0.5)),
              borderRadius: BorderRadius.circular(FarmRadii.sm),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.storage_outlined, size: 17, color: FarmColors.ink),
                  const SizedBox(width: 8),
                  Text(context.t('demoMode'), style: FarmTypography.textTheme.titleSmall),
                ]),
                const SizedBox(height: 6),
                Text(context.t('demoLoginExplainer'), style: FarmTypography.textTheme.bodySmall),
                const SizedBox(height: 8),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilledButton.tonal(
                    onPressed: busy ? null : onUseDemo,
                    child: Text(context.t('openDemoFarm')),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: onToggleServerField,
            child: Text(showServerField ? 'Hide server address' : 'Connecting to a different server?'),
          ),
          if (showServerField) ...[
            TextField(controller: serverUrl, decoration: const InputDecoration(labelText: 'Server address', hintText: 'https://your-backend-host/api/v1')),
            const SizedBox(height: 8),
          ],
          const SizedBox(height: FarmSpacing.md),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: busy ? null : () => onSubmit(),
              child: busy
                  ? const SizedBox(height: 18, width: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : Text(context.t('startMyDay')),
            ),
          ),
        ],
      ),
    );
  }
}
