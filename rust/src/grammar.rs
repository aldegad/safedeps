//! The install grammar's vocabulary and patterns, as lib/install-grammar.sh
//! defines them. The strings are the same strings: `safedeps-core grammar`
//! prints each one, and scripts/measure/core-grammar-drift.sh compares them
//! with the values the shell file gives after it is sourced, so the two
//! cannot drift apart while both exist.

pub const NPM_VERBS: &str = "add|ci|cit|clean-?[iI]nstall|clean-?[iI]nstall-|clean-?[iI]nstall-?[tT]|clean-?[iI]nstall-?[tT]e|clean-?[iI]nstall-?[tT]es|clean-?[iI]nstall-?[tT]est|i|ic|in|ins|inst|insta|instal|install|install-?[cC]i|install-?[cC]i-|install-?[cC]i-?[tT]|install-?[cC]i-?[tT]e|install-?[cC]i-?[tT]es|install-?[cC]i-?[tT]est|install-?[cC]l|install-?[cC]le|install-?[cC]lea|install-?[cC]lean|install-?[tT]|install-?[tT]e|install-?[tT]es|install-?[tT]est|isnt|isnta|isntal|isntall|isntall-|isntall-?[cC]|isntall-?[cC]l|isntall-?[cC]le|isntall-?[cC]lea|isntall-?[cC]lean|it|si|sit|u|ud|udp|udpa|udpat|udpate|up|upd|upda|updat|update|upg|upgr|upgra|upgrad|upgrade";
pub const NPM_EXEC_VERBS: &str = "exe|exec|x";
pub const NPM_INIT_VERBS: &str = "cr|cre|crea|creat|create|ini|init|inn|inni|innit";
pub const NPM_LINK_VERBS: &str = "lin|link|ln";
pub const PNPM_VERBS: &str = "add|install|i|install-test|it|update|up|upgrade";
pub const YARN_VERBS: &str = "add|install|upgrade|up";
pub const BUN_VERBS: &str = "add|a|install|i|update|upgrade";

pub const EXECUTABLES: &str = "npm|npx|pnpm|pnpx|yarn|bun|bunx|pip[0-9.]*|python[0-9.]*|py|poetry|uv|uvx|pipx|pipenv|cargo|go|gem|bundle|mvn|dotnet";
pub const SHELLS: &str = "sh|bash|rbash|dash|ash|hush|ksh|ksh93|rksh|mksh|lksh|pdksh|oksh|yash|posh|zsh|csh|tcsh|fish";

pub const START: &str = "(^[[:space:]]*|[;&|(][[:space:]]*)";
pub const WORD_END_CLASS: &str = "[[:space:];&|()<>`]";
pub const OPTS: &str = "([[:space:]]+(--|--?[A-Za-z0-9][A-Za-z0-9_.-]*([=[:space:]][^[:space:]]+)?))*";
pub const OPERAND: &str = "[[:space:]]+[^-[:space:]][^[:space:]]*";
pub const NPM_REGISTRY_OPERAND: &str = "([Nn][Pp][Mm]:[^[:space:]]+|(@[^/@[:space:]]+/[^/@[:space:]]+|[^-./~@:[:space:]][^/@:[:space:]]*)(@([Nn][Pp][Mm]:[^[:space:]]*|[^./:[:space:]][^/:[:space:]]*)?)?)";
pub const NPM_REMOTE_SPEC: &str = "((git[+][A-Za-z]+|git|github|gitlab|bitbucket|gist|https?):[^[:space:]]+|[^:@%/[:space:].~-][^:@%/[:space:]]*/[^:@[:space:]/%]+(#[^[:space:]]*)?)";
pub const O: &str = "([[:space:]]+(--|--?[A-Za-z0-9][A-Za-z0-9_.-]*(=[^[:space:]]*)?([[:space:]]+[^-[:space:];&|][^[:space:];&|]*)*))*";

/// The patterns built from the pieces above, in the order the shell file
/// builds them.
pub struct Patterns {
    pub all_verbs: String,
    pub end: String,
    pub npm_remote_operand: String,
    pub npm_install_body: String,
    pub create_body: String,
    pub install_body: String,
    pub install_re: String,
    pub npm_install_re: String,
    pub raw_install_re: String,
    pub backstop_re: String,
}

pub fn patterns() -> Patterns {
    let all_verbs = format!(
        "{}|{}|{}|{}|{}|{}|dlx|get|run|inject|dependency:get|package",
        NPM_VERBS, NPM_LINK_VERBS, PNPM_VERBS, YARN_VERBS, BUN_VERBS, NPM_EXEC_VERBS
    );
    let end = format!("[}}]?({}|$)", WORD_END_CLASS);
    let npm_remote_operand = format!(
        "({spec}|[^@[:space:]]+@[^:.[:space:]]+[.][^:[:space:]]+:[^[:space:]]+|(@[^/@[:space:]]+/[^/@[:space:]]+|[^-./~@:[:space:]][^/@:[:space:]]*)@{spec})",
        spec = NPM_REMOTE_SPEC
    );
    let npm_install_body = format!(
        "npm{o}[[:space:]]+({v})|npm{o}[[:space:]]+({l})([[:space:]]+[^[:space:]]+)*[[:space:]]+({reg}|{rem})",
        o = O,
        v = NPM_VERBS,
        l = NPM_LINK_VERBS,
        reg = NPM_REGISTRY_OPERAND,
        rem = npm_remote_operand
    );
    let create_body = format!(
        "npm{o}[[:space:]]+({iv})|pnpm{o}[[:space:]]+create|yarn{o}[[:space:]]+create|bun{o}[[:space:]]+(create|c)",
        o = O,
        iv = NPM_INIT_VERBS
    );
    let o = O;
    let op = OPERAND;
    let install_body = [
        npm_install_body.clone(),
        format!("(npx|pnpx|bunx|uvx){o}{op}"),
        format!("npm{o}[[:space:]]+({ev}){o}{op}", ev = NPM_EXEC_VERBS),
        format!("({create_body}){o}{op}"),
        format!("pnpm{o}[[:space:]]+({pv}|dlx)", pv = PNPM_VERBS),
        format!(
            "yarn{o}([[:space:]]+(global|workspace[[:space:]]+[^[:space:]]+|workspaces[[:space:]]+foreach{o}))?{o}[[:space:]]+({yv}|dlx)",
            yv = YARN_VERBS
        ),
        format!("bun{o}[[:space:]]+({bv})", bv = BUN_VERBS),
        format!("bun{o}[[:space:]]+x{o}{op}"),
        format!("(pip[0-9.]*|(python[0-9.]*|py){o}[[:space:]]+-[A-Za-z0-9]*m[[:space:]]*pip){o}[[:space:]]+install"),
        format!("poetry{o}[[:space:]]+add"),
        format!("uv{o}[[:space:]]+(add|pip{o}[[:space:]]+install|tool{o}[[:space:]]+install)"),
        format!("uv{o}[[:space:]]+tool{o}[[:space:]]+run{o}{op}"),
        format!("pipx{o}[[:space:]]+(install|inject)"),
        format!("pipx{o}[[:space:]]+run{o}{op}"),
        format!("pipenv{o}[[:space:]]+install"),
        format!("cargo([[:space:]]+[+][^[:space:]]+)?{o}[[:space:]]+(add|install)"),
        format!("go{o}[[:space:]]+(get|install)"),
        format!("go{o}[[:space:]]+run([[:space:]]+[^[:space:]]+)*[[:space:]]+[^-[:space:]][^[:space:]]*@[^[:space:]]+"),
        format!("gem{o}[[:space:]]+install"),
        format!("bundle{o}[[:space:]]+add"),
        format!("mvn{o}[[:space:]]+([^[:space:]]*maven-dependency-plugin[^[:space:]]*:get|dependency:get)"),
        format!("dotnet{o}[[:space:]]+add([[:space:]]+[^-[:space:]][^[:space:]]*)?{o}[[:space:]]+package"),
        format!("dotnet{o}[[:space:]]+package{o}[[:space:]]+(add|update)"),
        format!("dotnet{o}[[:space:]]+tool{o}[[:space:]]+(install|update)"),
    ]
    .join("|");
    let install_re = format!("{}({}){}", START, install_body, end);
    let npm_install_re = format!("{}({}){}", START, npm_install_body, end);
    let raw_install_re = format!(
        "(^|[^A-Za-z0-9_./-])({})([^A-Za-z0-9_-]|$)|(npm|pnpm|yarn|bun)([^\"]*)(install|add|dlx)|pip[0-9]*[[:space:]]+install|cargo[[:space:]]+(add|install)|go[[:space:]]+(get|install)|gem[[:space:]]+install|bundle[[:space:]]+add|poetry[[:space:]]+add|uv[[:space:]]+(add|pip)|pipenv[[:space:]]+install|mvn([^\"]*)dependency:get|dotnet[[:space:]]+add[[:space:]]+package",
        install_body
    );
    let backstop_re = format!("{}|(^|[^a-zA-Z0-9_-])npx[[:space:]]+(@?[A-Za-z0-9._-])", raw_install_re);
    Patterns {
        all_verbs,
        end,
        npm_remote_operand,
        npm_install_body,
        create_body,
        install_body,
        install_re,
        npm_install_re,
        raw_install_re,
        backstop_re,
    }
}

/// `name=value` lines for every value the drift check compares.
pub fn dump() -> String {
    let p = patterns();
    let rows: Vec<(&str, String)> = vec![
        ("SAFEDEPS_G_NPM_VERBS", NPM_VERBS.into()),
        ("SAFEDEPS_G_NPM_EXEC_VERBS", NPM_EXEC_VERBS.into()),
        ("SAFEDEPS_G_NPM_INIT_VERBS", NPM_INIT_VERBS.into()),
        ("SAFEDEPS_G_NPM_LINK_VERBS", NPM_LINK_VERBS.into()),
        ("SAFEDEPS_G_PNPM_VERBS", PNPM_VERBS.into()),
        ("SAFEDEPS_G_YARN_VERBS", YARN_VERBS.into()),
        ("SAFEDEPS_G_BUN_VERBS", BUN_VERBS.into()),
        ("SAFEDEPS_G_ALL_VERBS", p.all_verbs.clone()),
        ("SAFEDEPS_G_EXECUTABLES", EXECUTABLES.into()),
        ("SAFEDEPS_G_SHELLS", SHELLS.into()),
        ("SAFEDEPS_G_START", START.into()),
        ("SAFEDEPS_G_WORD_END_CLASS", WORD_END_CLASS.into()),
        ("SAFEDEPS_G_END", p.end.clone()),
        ("SAFEDEPS_G_OPTS", OPTS.into()),
        ("SAFEDEPS_G_OPERAND", OPERAND.into()),
        ("SAFEDEPS_G_NPM_REGISTRY_OPERAND", NPM_REGISTRY_OPERAND.into()),
        ("SAFEDEPS_G_NPM_REMOTE_SPEC", NPM_REMOTE_SPEC.into()),
        ("SAFEDEPS_G_NPM_REMOTE_OPERAND", p.npm_remote_operand.clone()),
        ("SAFEDEPS_G_O", O.into()),
        ("SAFEDEPS_G_NPM_INSTALL_BODY", p.npm_install_body.clone()),
        ("SAFEDEPS_G_CREATE_BODY", p.create_body.clone()),
        ("SAFEDEPS_G_INSTALL_BODY", p.install_body.clone()),
        ("SAFEDEPS_G_INSTALL_RE", p.install_re.clone()),
        ("SAFEDEPS_G_NPM_INSTALL_RE", p.npm_install_re.clone()),
        ("SAFEDEPS_G_RAW_INSTALL_RE", p.raw_install_re.clone()),
        ("SAFEDEPS_G_BACKSTOP_RE", p.backstop_re.clone()),
        ("SAFEDEPS_G_NPM_OPTIONS", crate::tables::NPM_OPTIONS.into()),
        ("SAFEDEPS_G_NPM_SHORTHANDS", crate::tables::NPM_SHORTHANDS.into()),
        ("SAFEDEPS_G_NPM_OTHER", crate::tables::NPM_OTHER.into()),
        ("SAFEDEPS_G_COMMANDS", crate::tables::COMMANDS.into()),
        ("SAFEDEPS_G_VALUE_OPTIONS", crate::tables::VALUE_OPTIONS.into()),
        ("SAFEDEPS_G_LONG_OPTIONS", crate::tables::LONG_OPTIONS.into()),
        ("SAFEDEPS_G_PARSERS", crate::tables::PARSERS.into()),
    ];
    let mut s = String::new();
    for (k, v) in rows {
        s.push_str(k);
        s.push('=');
        s.push_str(&v);
        s.push('\n');
    }
    s
}
