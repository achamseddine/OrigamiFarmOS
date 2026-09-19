import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:provider/provider.dart';
import '../../app/build_info.dart';
import '../../auth/session_controller.dart';
import '../../core/i18n/strings.dart';
import '../../core/theme/colors.dart';
import '../../core/theme/spacing.dart';
import '../../core/theme/typography.dart';
import '../../core/widgets/app_icon.dart';
import '../../core/widgets/bekaa_backdrop.dart';
import '../../core/widgets/directional_icon.dart';
import '../../data/local/demo_mode.dart';

/// The landing screen, built to the Option C mockup: the valley along the
/// bottom, the mark and the name at full size above it, a greeting, and
/// two large choices.
///
/// Two ways in. Against a real deployment, signing in needs the farm
/// network — there is no way to verify a password or issue a token
/// without reaching the server — and that is the app's only online
/// requirement; everything behind it then works offline from the cached
/// session, permissions and farm data.
///
/// The second way exists because there is no deployment yet: this build
/// ships a whole farm inside it, and the demo account opens it with no
/// server at all. That path is a button of its own here rather than a
/// note in a box, so nobody is left at a login they cannot get past.
///
/// The mockup has no email or password on it, and that is not an
/// oversight to paper over: at rest this screen offers two choices, and
/// the credentials appear under "Start My Day" once that is the choice
/// someone has made. It costs one extra tap on a screen a worker sees
/// once per install, and it buys a first screen anyone can read.
///
/// Either way [SessionController] restores the session at launch, so a
/// worker sees this screen once and never again until they sign out.
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SingleTickerProviderStateMixin {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _passwordFocus = FocusNode();

  /// Built in [initState], not as a `late final` initialiser.
  ///
  /// A `late final` field is created on first *access*, and the only
  /// thing that touches this one is the server-address box — which is
  /// now behind two taps and usually never opened. So on most runs the
  /// first access was `dispose()`, which ran the initialiser, which
  /// called `context.read` on an element that was already deactivated.
  /// Flutter asserts on exactly that, and it is right to: the answer
  /// read out of a half-torn-down tree is not trustworthy.
  late final TextEditingController _serverUrl;

  /// Same reason, and the usual place for one anyway.
  late final AnimationController _sky;

  bool _showSignIn = false;
  bool _showServerField = false;
  bool _obscure = true;

  /// Which button started the attempt, so the spinner appears on the one
  /// that was actually pressed rather than always on the first.
  bool _demoPressed = false;

  @override
  void initState() {
    super.initState();
    _serverUrl = TextEditingController(text: context.read<SessionController>().baseUrl);
    // Drives the clouds and the flock. Ninety seconds for one crossing:
    // slow enough that it reads as weather rather than animation, and
    // slow enough that nobody filling in a password competes with it.
    _sky = AnimationController(vsync: this, duration: const Duration(seconds: 90))..repeat();
  }

  @override
  void dispose() {
    _sky.dispose();
    _email.dispose();
    _password.dispose();
    _serverUrl.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  /// "Start My Day" does two jobs: it opens the sign-in fields the first
  /// time, and submits them after that.
  Future<void> _startMyDay() async {
    if (!_showSignIn) {
      setState(() => _showSignIn = true);
      return;
    }
    setState(() => _demoPressed = false);
    await _submit();
  }

  Future<void> _submit() async {
    final session = context.read<SessionController>();
    final ok = await session.login(email: _email.text, password: _password.text, serverUrl: _showServerField ? _serverUrl.text : null);
    if (!mounted || ok) return;
    // The form shows this too, and keeps it. The SnackBar is the nudge
    // that something happened; ten seconds because four is not enough to
    // read a sentence that names a server build.
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(session.error ?? context.t('couldNotSignIn')),
        duration: const Duration(seconds: 10),
      ),
    );
  }

  /// Fills in the demo account and signs straight in, so nobody has to
  /// find the credentials in a README to open the app.
  Future<void> _useDemo() async {
    setState(() => _demoPressed = true);
    _email.text = DemoMode.username;
    _password.text = DemoMode.password;
    await _submit();
    if (mounted) setState(() => _demoPressed = false);
  }

  String _greetingKey() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'goodMorning';
    if (hour < 17) return 'goodAfternoon';
    return 'goodEvening';
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: Stack(
        children: [
          // The valley, edge to edge and alive, with the paper washing
          // down over its top half so everything above it stays readable.
          // This is the mockup's photograph, painted as vector geometry —
          // the tech spec is explicit that the mockup PNGs must never ship
          // as in-app backgrounds (§19, §24).
          Positioned.fill(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _sky,
                builder: (context, _) => BekaaBackdrop(drift: _sky.value),
              ),
            ),
          ),
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0, 0.38, 0.62, 1],
                  colors: [
                    FarmColors.stone,
                    FarmColors.stone.withOpacity(0.96),
                    FarmColors.stone.withOpacity(0.35),
                    FarmColors.stone.withOpacity(0.05),
                  ],
                ),
              ),
            ),
          ),
          SafeArea(
            child: LayoutBuilder(builder: (context, constraints) {
              final wide = constraints.maxWidth >= kTabletBreakpoint;
              final gutter = wide ? FarmSpacing.xxl : FarmSpacing.lg;
              // Centre while there is room, scroll the moment there isn't
              // — which is every landscape tablet with the keyboard up.
              // This screen used to be a bare Row inside a Center with no
              // scrollable anywhere, so in landscape the password field
              // and the button sat off the bottom edge, unreachable.
              return SingleChildScrollView(
                padding: EdgeInsets.symmetric(horizontal: gutter, vertical: FarmSpacing.lg),
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    minHeight: (constraints.maxHeight - FarmSpacing.lg * 2).clamp(0.0, double.infinity),
                  ),
                  child: Align(
                    // Start-aligned on a wide screen, the way the mockup
                    // sets it; centred when the screen is too narrow for
                    // that to look deliberate.
                    alignment: wide ? AlignmentDirectional.centerStart : Alignment.center,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 560),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const _Brand(),
                          const SizedBox(height: FarmSpacing.xl),
                          Row(
                            children: [
                              const AppIcon(FarmIcon.sun, size: 30, color: FarmColors.gold),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  context.t(_greetingKey()),
                                  style: FarmTypography.display(size: 30),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(context.t('welcomeSubline'), style: FarmTypography.textTheme.bodyLarge),
                          if (session.needsFirstOnlineLogin) ...[
                            const SizedBox(height: FarmSpacing.md),
                            const _Notice(icon: Icons.cloud_off, messageKey: 'firstLoginNeedsInternet'),
                          ],
                          const SizedBox(height: FarmSpacing.xl),
                          _BigButton(
                            icon: FarmIcon.sun,
                            label: context.t('startMyDay'),
                            primary: true,
                            busy: session.busy && !_demoPressed,
                            onPressed: session.busy ? null : _startMyDay,
                          ),
                          const SizedBox(height: 14),
                          _BigButton(
                            icon: FarmIcon.barn,
                            label: context.t('viewDemoFarm'),
                            primary: false,
                            busy: session.busy && _demoPressed,
                            onPressed: session.busy ? null : _useDemo,
                          ),
                          if (_showSignIn) ...[
                            const SizedBox(height: FarmSpacing.lg),
                            _SignInFields(
                              email: _email,
                              password: _password,
                              passwordFocus: _passwordFocus,
                              serverUrl: _serverUrl,
                              obscure: _obscure,
                              showServerField: _showServerField,
                              error: session.error,
                              busy: session.busy,
                              onToggleObscure: () => setState(() => _obscure = !_obscure),
                              onToggleServerField: () => setState(() => _showServerField = !_showServerField),
                              onSubmit: _submit,
                            ),
                          ],
                          const SizedBox(height: FarmSpacing.lg),
                          // Which build is on this tablet. Before sign-in,
                          // because that is when somebody is asking whether
                          // the new APK actually landed.
                          Text(
                            'App $kAppVersion',
                            style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }
}

/// The mark and the name, stacked as the mockup draws them and at the
/// size it draws them — this is the first thing the screen says.
class _Brand extends StatelessWidget {
  const _Brand();

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SvgPicture.asset('assets/logo/origami-farmos-mark.svg', width: 86, height: 86),
        const SizedBox(width: 18),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Origami', style: FarmTypography.display(size: 46, color: FarmColors.cedar)),
              Text('FarmOS', style: FarmTypography.display(size: 38, color: FarmColors.olive)),
            ],
          ),
        ),
      ],
    );
  }
}

/// A full-width choice: icon, label, and the arrow that says it opens
/// something. Sixty-eight pixels tall because this is pressed with a
/// working hand, sometimes gloved, often without looking closely.
class _BigButton extends StatelessWidget {
  const _BigButton({
    required this.icon,
    required this.label,
    required this.primary,
    required this.onPressed,
    this.busy = false,
  });

  final FarmIcon icon;
  final String label;
  final bool primary;
  final VoidCallback? onPressed;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final fill = primary ? FarmColors.cedar : FarmColors.card;
    final ink = primary ? FarmColors.white : FarmColors.ink;
    final accent = primary ? FarmColors.white : FarmColors.cedar;

    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(FarmRadii.sm),
      elevation: 0,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(FarmRadii.sm),
        child: Container(
          height: 68,
          padding: const EdgeInsets.symmetric(horizontal: 22),
          child: Row(
            children: [
              if (busy)
                SizedBox(height: 24, width: 24, child: CircularProgressIndicator(strokeWidth: 2.4, color: accent))
              else
                AppIcon(icon, size: 26, color: accent),
              const SizedBox(width: 16),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700, color: ink),
                ),
              ),
              ForwardChevron(size: 24, color: primary ? FarmColors.white : FarmColors.muted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Email, password, and the things that only matter when a sign-in is
/// going wrong. Hidden until "Start My Day" is the chosen path.
class _SignInFields extends StatelessWidget {
  const _SignInFields({
    required this.email,
    required this.password,
    required this.passwordFocus,
    required this.serverUrl,
    required this.obscure,
    required this.showServerField,
    required this.error,
    required this.busy,
    required this.onToggleObscure,
    required this.onToggleServerField,
    required this.onSubmit,
  });

  final TextEditingController email;
  final TextEditingController password;
  final FocusNode passwordFocus;
  final TextEditingController serverUrl;
  final bool obscure;
  final bool showServerField;

  /// Why the last attempt failed, shown here and left there.
  ///
  /// This used to be a SnackBar and nothing else: four seconds at the
  /// bottom of a tablet, gone before anyone could read it, photograph it
  /// or copy it. Someone debugging a sign-in would swear no error was
  /// shown at all — and be right, in every way that matters. It stays put
  /// now, and it is selectable so the text can be sent to whoever can act
  /// on it.
  final String? error;
  final bool busy;
  final VoidCallback onToggleObscure;
  final VoidCallback onToggleServerField;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(FarmSpacing.lg),
      decoration: BoxDecoration(
        color: FarmColors.card,
        borderRadius: FarmRadii.panel,
        boxShadow: FarmShadows.elevated,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(context.t('signInWithPassword'), style: FarmTypography.textTheme.titleLarge),
          const SizedBox(height: FarmSpacing.md),
          // A leading icon on each field: someone who reads slowly knows
          // which box is which before finishing the label.
          TextField(
            controller: email,
            autofocus: true,
            keyboardType: TextInputType.emailAddress,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: 17),
            decoration: InputDecoration(
              labelText: context.t('email'),
              prefixIcon: const Icon(Icons.person_outline, size: 24),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
            ),
            onSubmitted: (_) => passwordFocus.requestFocus(),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: password,
            focusNode: passwordFocus,
            obscureText: obscure,
            style: const TextStyle(fontSize: 17),
            decoration: InputDecoration(
              labelText: context.t('password'),
              prefixIcon: const Icon(Icons.lock_outline, size: 24),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              suffixIcon: IconButton(
                iconSize: 24,
                icon: Icon(obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                onPressed: onToggleObscure,
              ),
            ),
            onSubmitted: (_) => onSubmit(),
          ),
          if (error != null && !busy) ...[
            const SizedBox(height: FarmSpacing.md),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(FarmSpacing.md),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                error!,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
              ),
            ),
          ],
          const SizedBox(height: 4),
          TextButton(
            onPressed: onToggleServerField,
            child: Text(showServerField ? context.t('hideServerAddress') : context.t('differentServer')),
          ),
          if (showServerField)
            TextField(
              controller: serverUrl,
              // A URL, not prose. Without these Android's keyboard
              // capitalises the first word and autocorrects the rest, so
              // a typed address becomes ".../API/v1/" — and since paths
              // are case-sensitive, every request then 404s against a
              // server that is working perfectly.
              keyboardType: TextInputType.url,
              textCapitalization: TextCapitalization.none,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(labelText: context.t('serverAddress'), hintText: 'https://your-backend-host/api/v1'),
            ),
        ],
      ),
    );
  }
}

/// A tinted band for something the person needs to know before they try.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.messageKey});

  final IconData icon;
  final String messageKey;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: FarmColors.tint(FarmColors.warning, 0.14),
        borderRadius: BorderRadius.circular(FarmRadii.sm),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: FarmColors.warningInk),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              context.t(messageKey),
              style: FarmTypography.textTheme.bodyMedium?.copyWith(color: FarmColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}
