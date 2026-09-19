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
import '../../data/local/demo_mode.dart';

/// The sign-in screen, built to the v1 redesign review: the valley filling
/// one half of the tablet, a white card on the other, and everything
/// needed to get in visible at once.
///
/// Two ways in. Against a real deployment, signing in needs the farm
/// network — there is no way to verify a password or issue a token
/// without reaching the server — and that is the app's only online
/// requirement; everything behind it then works offline from the cached
/// session, permissions and farm data.
///
/// The second way exists because there is no deployment yet: this build
/// ships a whole farm inside it, and the demo account opens it with no
/// server at all. The review puts that under the fold as a quiet link
/// rather than a second big button, which is right — it is the way in
/// for whoever is evaluating the app, not for the farm.
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

  /// Built in [initState], not as a `late final` initialiser: a `late
  /// final` runs on first *access*, and the server box is rarely opened,
  /// so the first access used to be `dispose()` — reading a provider out
  /// of an element that was already torn down.
  late final TextEditingController _serverUrl;
  late final AnimationController _sky;

  bool _showServerField = false;
  bool _obscure = true;
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

  /// There is no self-service reset, and pretending otherwise would send
  /// somebody to an inbox that will never receive anything. A farm
  /// manager sets passwords from the office console; the honest answer is
  /// to say so.
  void _forgotPassword() {
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(context.t('forgotPassword')),
        content: Text(context.t('forgotPasswordBody'), style: FarmTypography.textTheme.bodyMedium),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: Text(context.t('close'))),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<SessionController>();

    return Scaffold(
      backgroundColor: FarmColors.stone,
      body: LayoutBuilder(builder: (context, constraints) {
        final wide = constraints.maxWidth >= kTabletBreakpoint;

        final card = _SignInCard(
          email: _email,
          password: _password,
          passwordFocus: _passwordFocus,
          serverUrl: _serverUrl,
          obscure: _obscure,
          showServerField: _showServerField,
          busy: session.busy,
          demoPressed: _demoPressed,
          needsNetwork: session.needsFirstOnlineLogin,
          error: session.error,
          onToggleObscure: () => setState(() => _obscure = !_obscure),
          onToggleServerField: () => setState(() => _showServerField = !_showServerField),
          onForgotPassword: _forgotPassword,
          onUseDemo: _useDemo,
          onSubmit: _submit,
        );

        final valley = _ValleyPanel(sky: _sky, wide: wide);

        if (!wide) {
          // Portrait: a band of valley across the top, the card under it,
          // the whole thing scrolling. It has to scroll — the keyboard
          // takes half a tablet and everything below it would otherwise
          // be unreachable, which is exactly the bug this screen had.
          return SafeArea(
            child: SingleChildScrollView(
              child: Column(
                children: [
                  SizedBox(height: 230, child: valley),
                  Padding(
                    padding: const EdgeInsets.all(FarmSpacing.lg),
                    child: card,
                  ),
                ],
              ),
            ),
          );
        }

        // Landscape: the card sits at the reading edge — right in Arabic,
        // left in English — because Row lays its children out in logical
        // order and the card is first.
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              flex: 48,
              child: SafeArea(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(horizontal: FarmSpacing.xxl, vertical: FarmSpacing.lg),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      minHeight: (constraints.maxHeight - FarmSpacing.lg * 2).clamp(0.0, double.infinity),
                    ),
                    child: Center(child: card),
                  ),
                ),
              ),
            ),
            Expanded(flex: 52, child: valley),
          ],
        );
      }),
    );
  }
}

/// The half of the screen that is a place rather than a form: the valley,
/// what the farm is for, and where it is.
class _ValleyPanel extends StatelessWidget {
  const _ValleyPanel({required this.sky, required this.wide});

  final AnimationController sky;
  final bool wide;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        RepaintBoundary(
          child: AnimatedBuilder(
            animation: sky,
            builder: (context, _) => BekaaBackdrop(drift: sky.value),
          ),
        ),
        // Enough paper over the painting for the headline to sit on it.
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [FarmColors.stone.withOpacity(0.72), FarmColors.stone.withOpacity(0.12)],
            ),
          ),
        ),
        SafeArea(
          child: Padding(
            padding: EdgeInsets.all(wide ? FarmSpacing.xl : FarmSpacing.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (wide) const Spacer(flex: 2),
                Text(
                  context.t('loginHeadline'),
                  style: FarmTypography.display(size: wide ? 44 : 26, height: 1.25),
                ),
                const SizedBox(height: FarmSpacing.md),
                Container(width: 64, height: 3, color: FarmColors.gold),
                const SizedBox(height: FarmSpacing.md),
                Text(
                  context.t('loginSubhead'),
                  style: FarmTypography.textTheme.bodyLarge?.copyWith(color: FarmColors.muted),
                ),
                if (wide) ...[
                  const Spacer(flex: 3),
                  const _FeatureRow(),
                  const SizedBox(height: FarmSpacing.lg),
                  Row(
                    children: [
                      const Icon(Icons.place_outlined, size: 18, color: FarmColors.ink),
                      const SizedBox(width: 6),
                      Text(
                        context.t('farmLocationLine'),
                        style: FarmTypography.textTheme.titleSmall,
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// What this is all for, in three words each. Not decoration: it is the
/// only thing on the screen that says what the company believes, and the
/// person signing in every morning is the one delivering it.
class _FeatureRow extends StatelessWidget {
  const _FeatureRow();

  @override
  Widget build(BuildContext context) {
    const items = [
      (FarmIcon.leaf, 'featureProductive'),
      (FarmIcon.people, 'featureCommunities'),
      (FarmIcon.harvestBasket, 'featureSustainable'),
    ];
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < items.length; i++) ...[
          if (i > 0)
            Container(
              width: 1,
              height: 46,
              margin: const EdgeInsets.symmetric(horizontal: FarmSpacing.md),
              color: FarmColors.ink.withOpacity(0.15),
            ),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AppIcon(items[i].$1, size: 24, color: FarmColors.cedar),
                const SizedBox(height: 8),
                Text(
                  context.t(items[i].$2),
                  style: FarmTypography.textTheme.bodySmall?.copyWith(
                    color: FarmColors.ink,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _SignInCard extends StatelessWidget {
  const _SignInCard({
    required this.email,
    required this.password,
    required this.passwordFocus,
    required this.serverUrl,
    required this.obscure,
    required this.showServerField,
    required this.busy,
    required this.demoPressed,
    required this.needsNetwork,
    required this.error,
    required this.onToggleObscure,
    required this.onToggleServerField,
    required this.onForgotPassword,
    required this.onUseDemo,
    required this.onSubmit,
  });

  final TextEditingController email;
  final TextEditingController password;
  final FocusNode passwordFocus;
  final TextEditingController serverUrl;
  final bool obscure;
  final bool showServerField;
  final bool busy;
  final bool demoPressed;

  /// The last attempt couldn't reach the server at all. Say that plainly
  /// — a worker retyping a correct password is the failure mode here.
  final bool needsNetwork;

  /// Why the last attempt failed, shown on the card and left there.
  ///
  /// This used to be a SnackBar and nothing else: four seconds at the
  /// bottom of a tablet, gone before anyone could read it, photograph it
  /// or copy it. It stays put now, and it is selectable so the text can
  /// be sent to whoever can act on it.
  final String? error;

  final VoidCallback onToggleObscure;
  final VoidCallback onToggleServerField;
  final VoidCallback onForgotPassword;
  final Future<void> Function() onUseDemo;
  final Future<void> Function() onSubmit;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: const EdgeInsets.all(FarmSpacing.xl),
      decoration: BoxDecoration(
        color: FarmColors.card,
        borderRadius: FarmRadii.panel,
        boxShadow: FarmShadows.elevated,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              SvgPicture.asset('assets/logo/origami-farmos-mark.svg', width: 46, height: 46),
              const SizedBox(width: 12),
              Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Origami', style: FarmTypography.display(size: 24, color: FarmColors.ink)),
                  Text('FarmOS', style: FarmTypography.display(size: 20, color: FarmColors.olive)),
                ],
              ),
            ],
          ),
          const SizedBox(height: FarmSpacing.xl),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Flexible(
                child: Text(
                  context.t('startMyDay'),
                  textAlign: TextAlign.center,
                  style: FarmTypography.display(size: 34),
                ),
              ),
              const SizedBox(width: 12),
              const AppIcon(FarmIcon.sun, size: 30, color: FarmColors.gold),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            context.t('startMyDaySubtitle'),
            textAlign: TextAlign.center,
            style: FarmTypography.textTheme.bodyMedium?.copyWith(color: FarmColors.muted),
          ),
          if (needsNetwork) ...[
            const SizedBox(height: FarmSpacing.lg),
            _Notice(icon: Icons.cloud_off, message: context.t('firstLoginNeedsInternet')),
          ],
          const SizedBox(height: FarmSpacing.xl),
          _Field(
            label: context.t('loginEmailLabel'),
            child: TextField(
              controller: email,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: context.t('loginEmailHint'),
                prefixIcon: const Icon(Icons.mail_outline, size: 22),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              ),
              onSubmitted: (_) => passwordFocus.requestFocus(),
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          _Field(
            label: context.t('loginPasswordLabel'),
            child: TextField(
              controller: password,
              focusNode: passwordFocus,
              obscureText: obscure,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                hintText: context.t('loginPasswordHint'),
                prefixIcon: IconButton(
                  iconSize: 22,
                  icon: Icon(obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                  onPressed: onToggleObscure,
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 20),
              ),
              onSubmitted: (_) => onSubmit(),
            ),
          ),
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              onPressed: onForgotPassword,
              child: Text(context.t('forgotPassword')),
            ),
          ),
          if (error != null && !busy) ...[
            const SizedBox(height: 4),
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
            const SizedBox(height: FarmSpacing.sm),
          ],
          SizedBox(
            height: 64,
            child: FilledButton(
              onPressed: busy ? null : () => onSubmit(),
              style: FilledButton.styleFrom(
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FarmRadii.sm)),
              ),
              child: busy && !demoPressed
                  ? const SizedBox(height: 22, width: 22, child: CircularProgressIndicator(strokeWidth: 2.4, color: FarmColors.white))
                  : Row(
                      children: [
                        Expanded(
                          child: Text(
                            context.t('startMyDay'),
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontSize: 19, fontWeight: FontWeight.w700),
                          ),
                        ),
                        const _ForwardArrowGlyph(),
                      ],
                    ),
            ),
          ),
          const SizedBox(height: FarmSpacing.lg),
          Row(
            children: [
              const Expanded(child: Divider(color: FarmColors.border)),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Text(context.t('orDivider'), style: FarmTypography.textTheme.bodySmall),
              ),
              const Expanded(child: Divider(color: FarmColors.border)),
            ],
          ),
          const SizedBox(height: FarmSpacing.sm),
          Center(
            child: TextButton.icon(
              onPressed: busy ? null : onUseDemo,
              icon: busy && demoPressed
                  ? const SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.open_in_new, size: 18),
              label: Text(
                context.t('tryDemo'),
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
              ),
            ),
          ),
          Center(
            child: Text(
              context.t('tryDemoSub'),
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
            ),
          ),
          const SizedBox(height: FarmSpacing.md),
          // The server address and the build stamp: the two things that
          // only matter when somebody is working out why a tablet is not
          // behaving, kept to one quiet line each.
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: onToggleServerField,
              child: Text(
                showServerField ? context.t('hideServerAddress') : context.t('differentServer'),
                style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
              ),
            ),
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
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              'App $kAppVersion',
              style: FarmTypography.textTheme.bodySmall?.copyWith(color: FarmColors.muted),
            ),
          ),
        ],
      ),
    );
  }
}

/// A label sitting above its field, the way the review draws them —
/// rather than a floating label that moves when you type. A label that
/// stays put is one less thing moving on a screen somebody is reading
/// slowly.
class _Field extends StatelessWidget {
  const _Field({required this.label, required this.child});

  final String label;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: FarmTypography.textTheme.titleSmall),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

/// The arrow on the primary button: it points the way the language runs,
/// so it is a left arrow in Arabic and a right arrow in English.
class _ForwardArrowGlyph extends StatelessWidget {
  const _ForwardArrowGlyph();

  @override
  Widget build(BuildContext context) {
    final rtl = Directionality.of(context) == TextDirection.rtl;
    return Icon(rtl ? Icons.arrow_back : Icons.arrow_forward, size: 22, color: FarmColors.white);
  }
}

/// A tinted band for something the person needs to know before they try.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.message});

  final IconData icon;
  final String message;

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
              message,
              style: FarmTypography.textTheme.bodyMedium?.copyWith(color: FarmColors.ink),
            ),
          ),
        ],
      ),
    );
  }
}
