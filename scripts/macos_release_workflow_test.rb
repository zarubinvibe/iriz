#!/usr/bin/env ruby
# Offline checks of the real workflow snippets; no GitHub calls or builds.
require 'yaml'
require 'json'
require 'open3'
require 'tmpdir'

abort 'Usage: ruby scripts/macos_release_workflow_test.rb [--selftest]' unless ARGV.empty? || ARGV == ['--selftest']
workflow = YAML.safe_load(File.read(File.expand_path('../.github/workflows/macos-release.yml', __dir__)))
def check(condition, message)
  raise message unless condition
end

events = workflow['on'] || workflow[true] # Ruby's bundled YAML 1.1 treats "on" as true.
check(events.keys.sort == %w[push workflow_dispatch], 'Only manual and tag triggers are allowed')
check(events['push'] == { 'tags' => ['v*'] }, 'Push must be limited to version tags')
build_only = events.fetch('workflow_dispatch').fetch('inputs').fetch('build_only')
check(build_only['type'] == 'boolean' && build_only['default'] == false, 'build_only must be a boolean defaulting to false')
check(build_only['description'].is_a?(String) && !build_only['description'].empty?, 'build_only must explain its purpose')
check(workflow['permissions'] == { 'contents' => 'read' }, 'Default token must be read-only')
build, draft = workflow.fetch('jobs').values_at('build', 'draft')
guard = "github.repository == 'zarubinvibe/iriz' && github.event.repository.visibility == 'public'"
draft_guard = "#{guard} && !(github.event_name == 'workflow_dispatch' && inputs.build_only)"
check(build['if'] == guard, 'Private repositories and forks must be skipped without disabling build_only builds')
check(draft['if'] == draft_guard, 'Only manual build_only runs may skip the draft in the public source repository')
[
  ['manual draft', 'zarubinvibe/iriz', 'public', 'workflow_dispatch', false, true, true],
  ['manual artifacts only', 'zarubinvibe/iriz', 'public', 'workflow_dispatch', true, true, false],
  ['tag draft', 'zarubinvibe/iriz', 'public', 'push', nil, true, true],
  ['tag ignores manual input', 'zarubinvibe/iriz', 'public', 'push', true, true, true],
  ['private manual skip', 'zarubinvibe/iriz', 'private', 'workflow_dispatch', false, false, false],
  ['private build-only skip', 'zarubinvibe/iriz', 'private', 'workflow_dispatch', true, false, false],
  ['fork manual skip', 'fixture/iriz', 'public', 'workflow_dispatch', false, false, false],
  ['fork tag skip', 'fixture/iriz', 'public', 'push', nil, false, false]
].each do |name, repository, visibility, event, input, expected_build, expected_draft|
  values = { 'github.repository' => repository, 'github.event.repository.visibility' => visibility,
             'github.event_name' => event, 'inputs.build_only' => input }
  # Expressions are fixed by the equality checks above; evaluate only literal substitutions.
  actual = [build, draft].map do |job|
    expression = job['if'].gsub(/github\.event\.repository\.visibility|github\.repository|github\.event_name|inputs\.build_only/) do |key|
      values.fetch(key).inspect
    end
    eval(expression) # Ruby and GitHub share ==, && and ! for these literals.
  end
  check(actual == [expected_build, expected_draft], "#{name}: unexpected job conditions #{actual.inspect}")
  puts "PASS #{name}"
end
check(build['permissions'] == { 'contents' => 'read' }, 'Build must not receive a write token')
check(draft['permissions'] == { 'contents' => 'write' } && draft['needs'] == 'build', 'Draft must depend on the read-only build')
check(build['runs-on'] == 'macos-26' && build['env']['SMLTLK_SIGN_IDENTITY'] == '-', 'Build must use standard ARM64 and ad-hoc signing')
check(build['env']['DEVELOPER_DIR'] == '/Applications/Xcode_26.6.app/Contents/Developer', 'Pin the Xcode 26.6 toolchain')
check(build['env']['IRIZ_NOTARY_PROFILE'] == '' && build['env']['IRIZ_DMG_HEADLESS'] == '1', 'No Apple credentials or Finder in CI')
check(build['steps'].any? { |step| step['run'] == 'swift test --no-parallel --jobs 2' }, 'Serial tests must precede packaging')
test_index = build['steps'].index { |step| step['run'] == 'swift test --no-parallel --jobs 2' }
environment_index = build['steps'].index { |step| step['name'] == 'Prepare hosted macOS integration environment' }
check(environment_index && environment_index == test_index - 1, 'Environment preparation must immediately precede tests')
check(!build['continue-on-error'] && build['steps'].none? { |step| step['continue-on-error'] }, 'Build failures must stop subsequent steps')
package_index = build['steps'].index { |step| step['run'] == 'bash scripts/make_release.sh' }
check(package_index && test_index < package_index, 'Packaging must follow successful tests')
check(build['steps'].none? { |step| step.key?('if') }, 'build_only must retain every build, test, verification and upload step')
check(build['steps'].any? { |step| step['name'] == 'Verify the exact release files' }, 'Build must verify its release files')
upload = build['steps'].find { |step| step['id'] == 'upload' }
check(upload && upload.fetch('with')['overwrite'] == false, 'Build artifacts must upload without overwriting another run')
check(draft['steps'].none? { |step| step['uses'].to_s.start_with?('actions/checkout@') }, 'No checkout in the write job')
workflow['jobs'].each_value do |job|
  job['steps'].each do |step|
    if step['uses']
      check(step['uses'].match?(/\Aactions\/(checkout|upload-artifact|download-artifact)@[0-9a-f]{40}\z/), 'Use only SHA-pinned official actions')
    end
    next unless step['run']
    output, status = Open3.capture2e('bash', '-n', stdin_data: step['run'])
    check(status.success?, "Invalid Bash in #{step['name']}: #{output}")
  end
end
puts 'PASS workflow triggers, permissions, pins and Bash syntax'

environment_script = build['steps'][environment_index].fetch('run')
helper = File.read(File.join(__dir__, 'macos_ci_environment.swift'))
native_guard = <<'SWIFT'
if prepare {
    let environment = ProcessInfo.processInfo.environment
    require(environment["GITHUB_ACTIONS"] == "true"
            && environment["RUNNER_ENVIRONMENT"] == "github-hosted"
            && environment["RUNNER_OS"] == "macOS",
            "Fixture writes require a GitHub-hosted macOS runner.")
}
SWIFT
check(helper.split('func layouts', 2).first.include?(native_guard), 'The native helper must guard all writes independently of Bash')
check(helper.include?('let prepare = arguments == ["--prepare-hosted"]'), 'Only the explicit prepare mode may write')
prepare_body = helper[/^if prepare \{\n    let enabled = .*?^\}/m]
%w[TISEnableInputSource CFPreferencesSetValue CFPreferencesSynchronize].each do |call|
  check(prepare_body && helper.scan(/\b#{call}\(/).size == 1 && prepare_body.include?("#{call}("), "#{call} must only run inside the guarded prepare mode")
end
check(!helper.match?(/TISSelectInputSource|AppleLanguages|AppleLocale|setPersistentDomain|CFPreferencesSetAppValue/), 'Never select a layout or replace system language preferences')
check(helper.include?('let englishIDs = ["com.apple.keylayout.US", "com.apple.keylayout.ABC"]') &&
      helper.include?('let russianID = "com.apple.keylayout.Russian"'), 'Only the Apple EN/RU layout IDs are allowed')
check(helper.include?('let languageKey = "ru.smltlk.interfaceLanguage" as CFString') &&
      helper.include?('CFPreferencesSetValue(languageKey, "ru" as CFString, kCFPreferencesAnyApplication,') &&
      helper.include?('UserDefaults.standard.string(forKey: languageKey as String) == "ru"'), 'The iriz-only global preference needs an effective Foundation readback')
puts 'PASS native helper write boundary and exact fixture scope'

environment_commands = <<'BASH'
xcrun() {
  case "$*" in
    'swift scripts/macos_ci_environment.swift --prepare-hosted')
      printf 'FIXTURE_PREPARE\n'; return "$MOCK_PREPARE_EXIT" ;;
    'swift scripts/macos_ci_environment.swift --check')
      printf 'FIXTURE_CHECK\n'; return "$MOCK_CHECK_EXIT" ;;
    *) printf 'Unexpected xcrun arguments\n' >&2; return 99 ;;
  esac
}
swift() {
  [[ "$*" == 'test --no-parallel --jobs 2' ]] || return 99
  printf 'FIXTURE_TESTS\n'
}
BASH
[
  ['hosted fixture then tests', {}, 0, %w[FIXTURE_PREPARE FIXTURE_CHECK FIXTURE_TESTS]],
  ['fixture preparation failure stops tests', { 'MOCK_PREPARE_EXIT' => '37' }, 37, %w[FIXTURE_PREPARE]],
  ['fixture readback failure stops tests', { 'MOCK_CHECK_EXIT' => '38' }, 38, %w[FIXTURE_PREPARE FIXTURE_CHECK]],
  ['local runner cannot prepare', { 'GITHUB_ACTIONS' => nil }, 1, []],
  ['false Actions flag cannot prepare', { 'GITHUB_ACTIONS' => 'false' }, 1, []],
  ['missing runner environment cannot prepare', { 'RUNNER_ENVIRONMENT' => nil }, 1, []],
  ['self-hosted runner cannot prepare', { 'RUNNER_ENVIRONMENT' => 'self-hosted' }, 1, []],
  ['missing runner OS cannot prepare', { 'RUNNER_OS' => nil }, 1, []],
  ['non-macOS runner cannot prepare', { 'RUNNER_OS' => 'Linux' }, 1, []]
].each do |name, overrides, expected_status, expected_calls|
  env = { 'GITHUB_ACTIONS' => 'true', 'RUNNER_ENVIRONMENT' => 'github-hosted', 'RUNNER_OS' => 'macOS',
          'MOCK_PREPARE_EXIT' => '0', 'MOCK_CHECK_EXIT' => '0' }.merge(overrides)
  # Both commands are mocks; the real helper never prepares this machine.
  script = environment_commands + environment_script + "\n" + build['steps'][test_index].fetch('run')
  output, status = Open3.capture2e(env, 'bash', '-e', '-o', 'pipefail', '-c', script)
  check(status.exitstatus == expected_status && output.lines.map(&:strip).grep(/^FIXTURE_/) == expected_calls, "#{name}: #{output}")
  check(!expected_calls.empty? || output.include?('Fixture writes require a GitHub-hosted macOS runner.'), "#{name}: missing guard reason")
  puts "PASS #{name}"
end

sha = 'a' * 40
version_script = build['steps'].find { |step| step['id'] == 'version' }.fetch('run')
toolchain = <<'BASH'
uname() { [[ "$*" == '-m' ]] || return 99; printf '%s\n' "$MOCK_ARCH"; }
xcodebuild() { [[ "$*" == '-version' ]] || return 99; printf '%s\n' "$MOCK_XCODE"; }
xcrun() {
  case "$*" in
    'swift --version') printf '%s\n' "$MOCK_SWIFT" ;;
    '--sdk macosx --show-sdk-version')
      if [[ "$MOCK_SDK_EXIT" != 0 ]]; then printf 'Synthetic SDK lookup failure\n' >&2; return "$MOCK_SDK_EXIT"; fi
      printf '%s\n' "$MOCK_SDK"
      ;;
    *) printf 'Unexpected xcrun arguments\n' >&2; return 99 ;;
  esac
}
git() { [[ "$*" == 'rev-parse HEAD' ]] || return 99; printf '%s\n' "$SOURCE_SHA"; }
BASH
Dir.mktmpdir('iriz-workflow-test-') do |fixture|
  defaults = { version: '0.2.1', ref_type: 'branch', ref_name: 'main', arch: 'arm64',
               swift: 'Apple Swift version 6.3.3 (swiftlang-6.3.3.1.3 clang-2100.1.1.101)',
               xcode: "Xcode 26.6\nBuild version 17F113", sdk: '26.5' }
  [
    ['manual version', {}, nil],
    ['matching version tag', { ref_type: 'tag', ref_name: 'v0.2.1' }, nil],
    ['newer SDK', { sdk: '27.0' }, nil],
    ['SDK major only', { sdk: '26' }, nil],
    ['mismatched version tag', { ref_type: 'tag', ref_name: 'v0.2.2' }, 'The tag must match RELEASE_VERSION.'],
    ['invalid version', { version: '../bad' }, 'Invalid RELEASE_VERSION'],
    ['Intel runner', { arch: 'x86_64' }, 'An ARM64 runner is required.'],
    ['old Xcode', { xcode: 'Xcode 16.4' }, 'Xcode 26.6 build 17F113 is required.'],
    ['older Xcode 26', { xcode: "Xcode 26.3\nBuild version 17C529" }, 'Xcode 26.6 build 17F113 is required.'],
    ['wrong Xcode build', { xcode: "Xcode 26.6\nBuild version 17F114" }, 'Xcode 26.6 build 17F113 is required.'],
    ['old Swift', { swift: 'Swift version 5.10' }, 'Swift 6.3.3 is required.'],
    ['older Swift 6', { swift: 'Apple Swift version 6.2.3' }, 'Swift 6.3.3 is required.'],
    ['Swift patch prefix', { swift: 'Apple Swift version 6.3.30' }, 'Swift 6.3.3 is required.'],
    ['old SDK', { sdk: '15.5' }, 'macOS SDK 26 or newer is required.'],
    ['empty SDK', { sdk: '' }, 'macOS SDK 26 or newer is required.'],
    ['malformed SDK', { sdk: '26.2-beta' }, 'macOS SDK 26 or newer is required.'],
    ['SDK lookup failure', { sdk_exit: 42 }, 'Synthetic SDK lookup failure']
  ].each do |name, overrides, error|
    values = defaults.merge(overrides)
    File.write(File.join(fixture, 'RELEASE_VERSION'), values[:version] + "\n")
    env = { 'SOURCE_SHA' => sha, 'GITHUB_OUTPUT' => File::NULL, 'GITHUB_REF_TYPE' => values[:ref_type],
            'GITHUB_REF_NAME' => values[:ref_name], 'MOCK_ARCH' => values[:arch], 'MOCK_SWIFT' => values[:swift],
            'MOCK_XCODE' => values[:xcode], 'MOCK_SDK' => values[:sdk], 'MOCK_SDK_EXIT' => values.fetch(:sdk_exit, 0).to_s }
    output, status = Open3.capture2e(env, 'bash', '-c', toolchain + version_script, chdir: fixture)
    check(error ? status.exitstatus == values.fetch(:sdk_exit, 1) && output.lines.map(&:strip).include?(error) : status.success?, "#{name}: #{output}")
    puts "PASS #{name}"
  end
end

draft_script = draft['steps'].find { |step| step['name'] == 'Create a new draft only' }.fetch('run')
github = <<'BASH'
gh() {
  if [[ "$1" == api && "$4" == *'/releases?'* ]]; then
    [[ "$FAIL_API" != releases ]] || return 42
    printf '%s\n' "$RELEASES_JSON"
  elif [[ "$1" == api && "$4" == *'/tags?'* ]]; then
    [[ "$FAIL_API" != tags ]] || return 43
    printf '%s\n' "$TAGS_JSON"
  elif [[ "$1" == release && "$2" == create ]]; then
    printf 'CREATE_ARG:%s\n' "$@"
  else
    printf 'Unexpected gh call\n' >&2
    return 99
  fi
}
BASH
[
  ['new draft', '[[]]', '[[]]', '', true],
  ['existing draft', [[{ 'tag_name' => 'v0.2.1', 'draft' => true }]].to_json, '[[]]', '', false],
  ['existing public release', [[{ 'tag_name' => 'v0.2.1', 'draft' => false }]].to_json, '[[]]', '', false],
  ['matching tag commit', '[[]]', [[{ 'name' => 'v0.2.1', 'commit' => { 'sha' => sha } }]].to_json, '', true],
  ['different tag commit', '[[]]', [[{ 'name' => 'v0.2.1', 'commit' => { 'sha' => 'b' * 40 } }]].to_json, '', false],
  ['release API failure', '[[]]', '[[]]', 'releases', false],
  ['tags API failure', '[[]]', '[[]]', 'tags', false],
  ['malformed release response', 'invalid JSON', '[[]]', '', false]
].each do |name, releases, tags, failure, expected|
  env = { 'RELEASE_VERSION' => '0.2.1', 'SOURCE_SHA' => sha, 'GH_REPO' => 'zarubinvibe/iriz',
          'GH_TOKEN' => 'synthetic-unused', 'GITHUB_STEP_SUMMARY' => File::NULL,
          'RELEASES_JSON' => releases, 'TAGS_JSON' => tags, 'FAIL_API' => failure }
  output, status = Open3.capture2e(env, 'bash', '-c', github + draft_script)
  check(status.success? == expected && output.include?('CREATE_ARG:') == expected, "#{name}: #{output}")
  if expected
    %w[--draft --latest=false iriz-0.2.1-arm64.dmg iriz-macos-arm64.dmg SHA256SUMS.txt release-manifest.json].each do |arg|
      check(output.include?("CREATE_ARG:#{arg}\n"), "Missing create argument: #{arg}")
    end
    check(!output.include?('--clobber'), 'Asset overwrite is forbidden')
  end
  puts "PASS #{name}"
end
