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
check(workflow['permissions'] == { 'contents' => 'read' }, 'Default token must be read-only')
build, draft = workflow.fetch('jobs').values_at('build', 'draft')
guard = "github.repository == 'zarubinvibe/iriz' && github.event.repository.visibility == 'public'"
[build, draft].each { |job| check(job['if'] == guard, 'Private repositories and forks must be skipped') }
check(build['permissions'] == { 'contents' => 'read' }, 'Build must not receive a write token')
check(draft['permissions'] == { 'contents' => 'write' } && draft['needs'] == 'build', 'Draft must depend on the read-only build')
check(build['runs-on'] == 'macos-15' && build['env']['SMLTLK_SIGN_IDENTITY'] == '-', 'Build must use standard ARM64 and ad-hoc signing')
check(build['env']['IRIZ_NOTARY_PROFILE'] == '' && build['env']['IRIZ_DMG_HEADLESS'] == '1', 'No Apple credentials or Finder in CI')
check(build['steps'].any? { |step| step['run'] == 'swift test --no-parallel --jobs 2' }, 'Serial tests must precede packaging')
test_index = build['steps'].index { |step| step['run'] == 'swift test --no-parallel --jobs 2' }
package_index = build['steps'].index { |step| step['run'] == 'bash scripts/make_release.sh' }
check(package_index && test_index < package_index, 'Packaging must follow successful tests')
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

sha = 'a' * 40
version_script = build['steps'].find { |step| step['id'] == 'version' }.fetch('run')
toolchain = <<'BASH'
uname() { printf '%s\n' "$MOCK_ARCH"; }
xcodebuild() { printf 'Xcode 16.4 (synthetic)\n'; }
xcrun() { printf '%s\n' "$MOCK_SWIFT"; }
git() { printf '%s\n' "$SOURCE_SHA"; }
BASH
Dir.mktmpdir('iriz-workflow-test-') do |fixture|
  [
    ['manual version', '0.2.1', 'branch', 'main', 'arm64', 'Swift version 6.1.2', true],
    ['matching version tag', '0.2.1', 'tag', 'v0.2.1', 'arm64', 'Swift version 6.1.2', true],
    ['mismatched version tag', '0.2.1', 'tag', 'v0.2.2', 'arm64', 'Swift version 6.1.2', false],
    ['invalid version', '../bad', 'branch', 'main', 'arm64', 'Swift version 6.1.2', false],
    ['Intel runner', '0.2.1', 'branch', 'main', 'x86_64', 'Swift version 6.1.2', false],
    ['old Swift', '0.2.1', 'branch', 'main', 'arm64', 'Swift version 5.10', false]
  ].each do |name, version, ref_type, ref_name, arch, swift, expected|
    File.write(File.join(fixture, 'RELEASE_VERSION'), version + "\n")
    env = { 'SOURCE_SHA' => sha, 'GITHUB_OUTPUT' => File::NULL, 'GITHUB_REF_TYPE' => ref_type,
            'GITHUB_REF_NAME' => ref_name, 'MOCK_ARCH' => arch, 'MOCK_SWIFT' => swift }
    output, status = Open3.capture2e(env, 'bash', '-c', toolchain + version_script, chdir: fixture)
    check(status.success? == expected, "#{name}: #{output}")
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
