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
notes_check_index = build['steps'].index { |step| step['name'] == 'Verify generated GitHub Release notes' }
notes_check = notes_check_index && build['steps'][notes_check_index]
check(notes_check && notes_check['env'] == { 'RELEASE_VERSION' => '${{ steps.version.outputs.version }}' } &&
      notes_check['run'] == 'node scripts/render_github_release_notes.mjs --check --version "$RELEASE_VERSION"',
      'Build must verify the generated notes for the exact release version')
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
upload_index = build['steps'].index(upload)
stage_index = build['steps'].index { |step| step['name'] == 'Stage release notes for the draft' }
stage = stage_index && build['steps'][stage_index]
check(stage && stage['run'] == 'cp ".github/release-notes/v$RELEASE_VERSION.md" "release/dist/release-notes-v$RELEASE_VERSION.md"' &&
      package_index < stage_index && stage_index == upload_index - 1,
      'Verified release notes must be staged immediately before artifact upload')
artifact_paths = upload.fetch('with').fetch('path').lines.map(&:strip).reject(&:empty?)
check(artifact_paths == [
  'release/dist/iriz-${{ steps.version.outputs.version }}-arm64.dmg',
  'release/dist/iriz-macos-arm64.dmg',
  'release/dist/SHA256SUMS.txt',
  'release/dist/release-manifest.json',
  'release/dist/release-notes-v${{ steps.version.outputs.version }}.md'
], 'Actions artifact must contain four public assets plus the generated notes')
download = draft['steps'].find { |step| step['name'] == "Download only this build's artifact" }
check(download && download.fetch('with')['artifact-ids'] == '${{ needs.build.outputs.artifact_id }}' &&
      download.fetch('with')['path'] == 'release-files' && download.fetch('with')['merge-multiple'] == true &&
      download.fetch('with')['digest-mismatch'] == 'error', 'Draft must download only the exact verified build artifact')
draft_verify = draft['steps'].find { |step| step['name'] == 'Verify release metadata and checksums' }.fetch('run')
check(draft_verify.include?('release-manifest.json "release-notes-v$RELEASE_VERSION.md"') &&
      draft_verify.include?('[[ -f "$file" && ! -L "$file" && -s "$file" ]]'),
      'Draft must reject missing, empty or linked release notes')
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

draft_script = draft['steps'].find { |step| step['name'] == 'Create a new draft or leave the published release unchanged' }.fetch('run')
github = <<'BASH'
gh() {
  printf '%s\n' "$*" >> "$GH_CALL_LOG"
  if [[ "$*" == "api --paginate --slurp repos/$GH_REPO/releases?per_page=100" ]]; then
    [[ "$FAIL_API" != releases ]] || return "$API_EXIT"
    printf '%s\n' "$RELEASES_JSON"
  elif [[ "$*" == "api --paginate --slurp repos/$GH_REPO/tags?per_page=100" ]]; then
    [[ "$FAIL_API" != tags ]] || return "$API_EXIT"
    printf '%s\n' "$TAGS_JSON"
  elif [[ "$*" == "api --method GET repos/$GH_REPO/git/ref/tags/v0.2.1" ]]; then
    [[ "$FAIL_API" != ref ]] || return "$API_EXIT"
    printf '%s\n' "$REF_JSON"
  elif [[ "$#" == 4 && "$1 $2 $3" == 'api --method GET' && "$4" == "repos/$GH_REPO/git/tags/"* ]]; then
    [[ "$FAIL_API" != annotation ]] || return "$API_EXIT"
    jq -er --arg sha "${4##*/}" '.[$sha] // error("Missing fixture annotation")' <<< "$TAG_OBJECTS_JSON"
  elif [[ "$1" == release && "$2" == create ]]; then
    printf 'CREATE_ARG:%s\n' "$@"
  else
    printf 'Unexpected gh call\n' >&2
    return 99
  fi
}
BASH
tag = 'v0.2.1'
annotation_sha = 'b' * 40
nested_sha = 'c' * 40
published = { 'tag_name' => tag, 'draft' => false, 'target_commitish' => 'not-proof-of-source' }
commit_object = { 'type' => 'commit', 'sha' => sha }
reference = { 'ref' => "refs/tags/#{tag}", 'object' => commit_object }
tag_entry = { 'name' => tag, 'commit' => { 'sha' => sha } }
annotation = { 'sha' => annotation_sha, 'object' => commit_object }
defaults = { 'RELEASES_JSON' => [[published]].to_json, 'TAGS_JSON' => '[[]]', 'REF_JSON' => reference.to_json,
             'TAG_OBJECTS_JSON' => { annotation_sha => annotation }.to_json, 'FAIL_API' => '', 'API_EXIT' => '42' }
fixtures = [
  ['new draft', { 'RELEASES_JSON' => '[[]]' }, :create],
  ['matching tag commit creates draft', { 'RELEASES_JSON' => '[[]]', 'TAGS_JSON' => [[tag_entry]].to_json }, :create],
  ['different tag commit refuses draft', { 'RELEASES_JSON' => '[[]]', 'TAGS_JSON' => [[tag_entry.merge('commit' => { 'sha' => annotation_sha })]].to_json }, :fail],
  ['matching published release is unchanged', {}, :noop],
  ['matching published release on later page', { 'RELEASES_JSON' => [[], [published]].to_json }, :noop],
  ['matching annotated published tag', { 'REF_JSON' => reference.merge('object' => { 'type' => 'tag', 'sha' => annotation_sha }).to_json }, :noop],
  ['nested annotated published tag', { 'REF_JSON' => reference.merge('object' => { 'type' => 'tag', 'sha' => annotation_sha }).to_json,
     'TAG_OBJECTS_JSON' => { annotation_sha => annotation.merge('object' => { 'type' => 'tag', 'sha' => nested_sha }),
                             nested_sha => { 'sha' => nested_sha, 'object' => commit_object } }.to_json }, :noop],
  ['existing draft refuses writes', { 'RELEASES_JSON' => [[published.merge('draft' => true)]].to_json }, :fail],
  ['duplicate releases refuse writes', { 'RELEASES_JSON' => [[published, published]].to_json }, :fail],
  ['published tag points elsewhere despite commitish', { 'RELEASES_JSON' => [[published.merge('target_commitish' => sha)]].to_json,
     'REF_JSON' => reference.merge('object' => commit_object.merge('sha' => annotation_sha)).to_json }, :fail],
  ['different tag ref', { 'REF_JSON' => reference.merge('ref' => 'refs/tags/v0.2.2').to_json }, :fail],
  ['branch is not tag ref', { 'REF_JSON' => reference.merge('ref' => "refs/heads/#{tag}").to_json }, :fail],
  ['missing tag ref', { 'REF_JSON' => { 'object' => commit_object }.to_json }, :fail],
  ['invalid tag object type', { 'REF_JSON' => reference.merge('object' => commit_object.merge('type' => 'tree')).to_json }, :fail],
  ['missing tag object', { 'REF_JSON' => reference.merge('object' => nil).to_json }, :fail],
  ['missing tag SHA', { 'REF_JSON' => reference.merge('object' => { 'type' => 'commit' }).to_json }, :fail],
  ['tag SHA prefix cannot match', { 'REF_JSON' => reference.merge('object' => commit_object.merge('sha' => sha[0, 12])).to_json }, :fail],
  ['tag SHA substring cannot match', { 'REF_JSON' => reference.merge('object' => commit_object.merge('sha' => "0#{sha}")).to_json }, :fail],
  ['tag SHA must be hex', { 'REF_JSON' => reference.merge('object' => commit_object.merge('sha' => 'z' * 40)).to_json }, :fail],
  ['tag SHA trailing newline is not normalized', { 'REF_JSON' => reference.merge('object' => commit_object.merge('sha' => "#{sha}\n")).to_json }, :fail],
  ['listed tag SHA trailing newline is invalid', { 'RELEASES_JSON' => '[[]]', 'TAGS_JSON' => [[tag_entry.merge('commit' => { 'sha' => "#{sha}\n" })]].to_json }, :fail],
  ['tag API failure', { 'RELEASES_JSON' => '[[]]', 'FAIL_API' => 'tags' }, :fail],
  ['malformed tags response', { 'RELEASES_JSON' => '[[]]', 'TAGS_JSON' => '{}' }, :fail],
  ['concatenated tag documents refuse draft', { 'RELEASES_JSON' => '[[]]', 'TAGS_JSON' => "[[]]\n[[]]" }, :fail],
  ['concatenated release documents', { 'RELEASES_JSON' => "[[]]\n[[]]" }, :fail],
  ['concatenated ref documents cannot discard invalid object', { 'REF_JSON' => reference.to_json + "\n" + reference.merge('object' => {}).to_json }, :fail],
  ['duplicate tags refuse draft', { 'RELEASES_JSON' => '[[]]', 'TAGS_JSON' => [[tag_entry, tag_entry]].to_json }, :fail]
]
[nil, 'false', 0].each do |value|
  fixtures << ["invalid draft value #{value.inspect}", { 'RELEASES_JSON' => [[published.merge('draft' => value)]].to_json }, :fail]
end
%w[draft tag_name].each do |key|
  fixtures << ["missing release #{key}", { 'RELEASES_JSON' => [[published.reject { |field, _| field == key }]].to_json }, :fail]
end
[nil, false, 42].each do |value|
  fixtures << ["invalid release tag #{value.inspect}", { 'RELEASES_JSON' => [[published.merge('tag_name' => value)]].to_json }, :fail]
end
['', 'invalid JSON', '{', '{}', 'null', '[]', '[{}]', '[[false]]'].each do |value|
  fixtures << ["malformed release response #{value.inspect}", { 'RELEASES_JSON' => value }, :fail]
end
['', 'invalid JSON', '[]', 'null'].each do |value|
  fixtures << ["malformed ref response #{value.inspect}", { 'REF_JSON' => value }, :fail]
end
%w[401 403 404 500].each do |http_status|
  %w[releases ref].each do |api|
    # gh reports HTTP failures as a nonzero command status, not a successful JSON body.
    fixtures << ["#{api} API HTTP #{http_status}", { 'FAIL_API' => api, 'API_EXIT' => '1' }, :fail]
  end
end
[
  ['different annotated commit', annotation.merge('object' => commit_object.merge('sha' => nested_sha))],
  ['wrong annotation SHA', annotation.merge('sha' => nested_sha)],
  ['missing annotation object', annotation.reject { |key, _| key == 'object' }],
  ['invalid annotation object type', annotation.merge('object' => commit_object.merge('type' => 'tree'))],
  ['cyclic annotation is bounded', annotation.merge('object' => { 'type' => 'tag', 'sha' => annotation_sha })],
  ['malformed annotation JSON', 'invalid JSON'],
  ['concatenated annotation documents cannot discard invalid object', annotation.to_json + "\n" + annotation.merge('object' => {}).to_json]
].each do |name, value|
  fixtures << [name, { 'REF_JSON' => reference.merge('object' => { 'type' => 'tag', 'sha' => annotation_sha }).to_json,
                       'TAG_OBJECTS_JSON' => { annotation_sha => value }.to_json }, :fail]
end
fixtures << ['annotation API failure', { 'REF_JSON' => reference.merge('object' => { 'type' => 'tag', 'sha' => annotation_sha }).to_json,
                                         'FAIL_API' => 'annotation' }, :fail]
Dir.mktmpdir('iriz-release-write-test-') do |fixture|
  fixtures.each do |name, overrides, expected|
    log_path = File.join(fixture, 'gh-calls.txt')
    File.write(log_path, '')
    env = { 'RELEASE_VERSION' => '0.2.1', 'SOURCE_SHA' => sha, 'GH_REPO' => 'zarubinvibe/iriz',
            'GH_TOKEN' => 'synthetic-unused', 'GITHUB_STEP_SUMMARY' => File::NULL, 'GH_CALL_LOG' => log_path }.merge(defaults).merge(overrides)
    output, status = Open3.capture2e(env, 'bash', '-c', github + draft_script)
    calls = File.readlines(log_path, chomp: true)
    writes = calls.reject { |call| call.start_with?('api --paginate --slurp ', 'api --method GET ') }
    check(!output.include?('Unexpected gh call'), "#{name}: unexpected API or write: #{calls.inspect}")
    check(status.success? == (expected != :fail), "#{name}: status #{status.exitstatus}: #{output}")
    check(output.include?('CREATE_ARG:') == (expected == :create), "#{name}: unexpected create: #{output}")
    check(output.include?('already published, left unchanged') == (expected == :noop), "#{name}: incorrect no-op claim: #{output}")
    if expected == :create
      check(writes.size == 1 && writes.first.start_with?("release create #{tag} "), "#{name}: unexpected writes: #{writes.inspect}")
      %w[--draft --latest=false iriz-0.2.1-arm64.dmg iriz-macos-arm64.dmg SHA256SUMS.txt release-manifest.json].each do |arg|
        check(output.include?("CREATE_ARG:#{arg}\n"), "Missing create argument: #{arg}")
      end
      check(output.include?("CREATE_ARG:--target\nCREATE_ARG:#{sha}\n"), 'Draft must target the exact source commit')
      check(output.include?("CREATE_ARG:--notes-file\nCREATE_ARG:release-notes-v0.2.1.md\n"),
            'Draft must use the generated notes file')
      check(!output.include?("CREATE_ARG:--notes\n"), 'Draft must not replace generated notes with inline copy')
      check(!output.include?('--clobber'), 'Asset overwrite is forbidden')
    else
      check(writes.empty?, "#{name}: no writes allowed: #{writes.inspect}")
    end
    if expected == :noop
      check(calls.include?("api --method GET repos/zarubinvibe/iriz/git/ref/tags/#{tag}"), "#{name}: exact real tag ref not checked")
      check(output.include?('Existing assets were not verified by this no-op.'), "#{name}: must not imply existing asset verification")
    end
    check(calls.count { |call| call.include?('/git/tags/') } <= 16, "#{name}: unbounded annotation lookup")
    puts "PASS #{name}"
  end
end
