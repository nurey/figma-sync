# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  describe '.main syncing a file' do
    context 'when the output folder is new' do
      it 'exports every frame, writes the manifest and exits 0' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('Mobile', frame('1:2', 'Home'), frame('1:3', 'Cart'))], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          manifest = read_manifest(out)
          expect(result.code).to eq(0)
          expect(files_under(out)).to eq(%w[.figma-sync.json Mobile/Cart__1-3.png Mobile/Home__1-2.png])
          expect(File.read(File.join(out, 'Mobile/Home__1-2.png'))).to eq('image from https://images.example/1:2')
          expect(manifest.keys).to eq(%w[fileKey manifestVersion version lastModified syncedAt scale format nodes])
          expect(manifest).to include('fileKey' => 'SimKey', 'version' => 'v2', 'scale' => 2.0, 'format' => 'png',
                                      'lastModified' => '2026-09-25T00:00:00Z')
          expect(manifest['syncedAt']).to match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\+00:00\z/)
          expect(manifest['manifestVersion']).to eq(2)
          expect(manifest_paths(out)).to eq('1:2' => 'Mobile/Home__1-2.png', '1:3' => 'Mobile/Cart__1-3.png')
          expect(result.stderr).to include("Fetching Sim file (depth 4)...\nHashing 2 frames in 1 requests...\n",
                                           "2 frames: 0 changed, 2 new, 0 unchanged\n[1/1] Mobile: 2 frames\n",
                                           "Exported 2 frames to #{out} (deleted 0 stale)")
        end
      end
    end

    context 'when the locale is US-ASCII and names contain emoji and accents' do
      it 'loads, exports, saves and reloads the manifest as UTF-8' do
        Dir.mktmpdir do |parent|
          out = File.join(parent, 'Miroir é')
          seed_manifest(out, nodes: { '1:1' => '🟡 Café/Accueil é__1-1.png', '9:9' => '🟡 Café/Gone ☕__9-9.png' })
          seed_file(out, '🟡 Café/Accueil é__1-1.png')
          seed_file(out, '🟡 Café/Gone ☕__9-9.png')
          stub_figma(pages: [page('🟡 Café', frame('1:1', 'Accueil é'), frame('1:2', 'Menu ☕'))], version: 'v2')

          with_default_external(Encoding::US_ASCII) do
            result = run_cli('SimKey', '--token', 'tok', '--out', locale_tagged(out))
            rerun = run_cli('SimKey', '--token', 'tok', '--out', locale_tagged(out))

            expect(result.code).to eq(0)
            expect(result.stderr).to include('[1/1] 🟡 Café: 2 frames', '(deleted 1 stale)')
            expect(rerun.stdout).to eq("Up to date (version v2)\n")
          end

          expect(files_under(out)).to eq(['.figma-sync.json', '🟡 Café/Accueil é__1-1.png', '🟡 Café/Menu ☕__1-2.png'])
          expect(manifest_paths(out)).to eq('1:1' => '🟡 Café/Accueil é__1-1.png', '1:2' => '🟡 Café/Menu ☕__1-2.png')
        end
      end
    end

    context 'when the locale is US-ASCII and only the case of an accented page changed' do
      it 'still renames the page folder to the new case' do
        Dir.mktmpdir do |out|
          skip 'needs a case-insensitive volume for the system temp dir' unless case_insensitive?(out)
          seed_manifest(out, nodes: { '1:2' => 'Café/Home__1-2.png' })
          seed_file(out, 'Café/Home__1-2.png')
          stub_figma(pages: [page('café', frame('1:2', 'Home'))])

          result = with_default_external(Encoding::US_ASCII) { run_cli('SimKey', '--token', 'tok', '--out', out) }

          expect(result.code).to eq(0)
          expect(Dir.children(out, encoding: Encoding::UTF_8).sort).to eq(%w[.figma-sync.json café])
        end
      end
    end

    context 'when the version, scale and format match the manifest' do
      it 'prints Up to date without fetching the full file' do
        Dir.mktmpdir do |out|
          seed_manifest(out, version: 'v2', nodes: {})
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(result.stdout).to eq("Up to date (version v2)\n")
          expect(client).not_to have_received(:get_file).with('SimKey', depth: 4)
          expect(client).not_to have_received(:image_urls)
        end
      end
    end

    context 'when the version matches but the scale differs' do
      it 'exports again' do
        Dir.mktmpdir do |out|
          seed_manifest(out, version: 'v2', scale: 1.0, nodes: {})
          stub_figma(pages: [page('P', frame('1:1', 'A'))], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('Exported 1 frames')
          expect(read_manifest(out)['scale']).to eq(2.0)
        end
      end
    end

    context 'when the version matches but the format differs' do
      it 'exports again in the new format' do
        Dir.mktmpdir do |out|
          seed_manifest(out, version: 'v2', format: 'png', nodes: {})
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))], version: 'v2')

          run_cli('SimKey', '--token', 'tok', '--out', out, '--format', 'svg')

          expect(client).to have_received(:image_urls).with('SimKey', ['1:1'], fmt: 'svg', scale: 2.0)
          expect(files_under(out)).to include('P/A__1-1.svg')
        end
      end
    end

    context 'when --force is given and nothing changed' do
      it 'exports anyway' do
        Dir.mktmpdir do |out|
          seed_manifest(out, version: 'v2', nodes: {})
          stub_figma(pages: [page('P', frame('1:1', 'A'))], version: 'v2')

          result = run_cli('SimKey', '--token', 'tok', '--out', out, '--force')

          expect(result.stdout).not_to include('Up to date')
          expect(files_under(out)).to include('P/A__1-1.png')
        end
      end
    end

    context 'when pages have more than 20 frames' do
      it 'requests batches of at most 20 ids that never span pages' do
        Dir.mktmpdir do |out|
          a_frames = (1..25).map { |i| frame("1:#{i}", "A#{i}") }
          b_frames = (1..3).map { |i| frame("2:#{i}", "B#{i}") }
          client = stub_figma(pages: [page('A', *a_frames), page('B', *b_frames)])
          requested = []
          allow(client).to receive(:image_urls) do |_key, ids, **|
            requested << ids
            ids.to_h { |id| [id, "https://images.example/#{id}"] }
          end

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(requested.map(&:size)).to eq([20, 5, 3])
          expect(requested.map { |ids| ids.map { |id| id.split(':').first }.uniq }).to eq([['1'], ['1'], ['2']])
          expect(result.stderr).to include('[1/3] A: 20 frames', '[2/3] A: 5 frames', '[3/3] B: 3 frames')
        end
      end
    end

    context 'when --dry-run is given' do
      it 'prints the plan for the frames within --limit and writes nothing' do
        Dir.mktmpdir do |parent|
          out = File.join(parent, 'mirror')
          stub_figma(pages: [page('P', frame('1:1', 'A'), frame('1:2', 'B'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out, '--dry-run', '--limit', '1')

          expect(result.code).to eq(0)
          expect(result.stdout).to eq("Output: #{out}\n1 frames: 0 changed, 1 new, 0 unchanged\n" \
                                      "Would export 1 frames in 1 batches\n  P/A__1-1.png  (new)\n" \
                                      "Would delete 0 stale file(s) for removed frames\n")
          expect(File.exist?(out)).to be(false)
        end
      end
    end

    context 'when a download fails' do
      it 'records the failure, leaves version null and exits 1' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'), frame('1:2', 'B'))])
          allow(client).to receive(:download).with('https://images.example/1:2', anything)
                                             .and_raise(FigmaSync::SyncError, 'download from images.example returned HTTP 403')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to include('    failed after retries: 1:2 (download from images.example returned HTTP 403)',
                                           '1 frame(s) failed: 1:2')
          expect(read_manifest(out)['version']).to be_nil
          expect(manifest_paths(out)).to eq('1:1' => 'P/A__1-1.png')
        end
      end
    end

    context 'when --limit is given' do
      it 'exports only that many frames and leaves version null' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', frame('1:1', 'A'), frame('1:2', 'B'), frame('1:3', 'C'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out, '--limit', '2')

          expect(result.code).to eq(0)
          expect(files_under(out)).to eq(%w[.figma-sync.json P/A__1-1.png P/B__1-2.png])
          expect(read_manifest(out)['version']).to be_nil
        end
      end
    end

    context 'when a limited run is repeated' do
      it 'checks again because the version was left null, but exports nothing unchanged' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          run_cli('SimKey', '--token', 'tok', '--out', out, '--limit', '1')

          result = run_cli('SimKey', '--token', 'tok', '--out', out, '--limit', '1')

          expect(result.stdout).not_to include('Up to date')
          expect(result.stderr).to include('1 frames: 0 changed, 0 new, 1 unchanged')
          expect(client).to have_received(:image_urls).once
        end
      end
    end

    context 'when a frame from the manifest no longer exists' do
      it 'deletes its file and drops it from the manifest' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '9:9' => 'Old/Gone__9-9.png' })
          seed_file(out, 'Old/Gone__9-9.png')
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('(deleted 1 stale)')
          expect(files_under(out)).to eq(%w[.figma-sync.json P/A__1-1.png])
          expect(Dir.exist?(File.join(out, 'Old'))).to be(false)
          expect(manifest_paths(out)).to eq('1:1' => 'P/A__1-1.png')
        end
      end
    end

    context 'when the output folder holds files the manifest does not know' do
      it 'leaves them alone' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '9:9' => 'Old/Gone__9-9.png' })
          seed_file(out, 'Old/Gone__9-9.png')
          seed_file(out, 'Old/notes.txt', 'mine')
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(files_under(out)).to eq(%w[.figma-sync.json Old/notes.txt P/A__1-1.png])
        end
      end
    end

    context 'when a frame was renamed' do
      it 'removes the file at the old path' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:2' => 'Mobile/Home__1-2.png' })
          seed_file(out, 'Mobile/Home__1-2.png')
          stub_figma(pages: [page('Mobile', frame('1:2', 'Landing'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('(deleted 1 stale)')
          expect(files_under(out)).to eq(%w[.figma-sync.json Mobile/Landing__1-2.png])
          expect(manifest_paths(out)).to eq('1:2' => 'Mobile/Landing__1-2.png')
        end
      end
    end

    context 'when only the case of a page and frame changed on a case-insensitive volume' do
      it 'keeps the file and renames it to the new case on disk' do
        Dir.mktmpdir do |out|
          skip 'needs a case-insensitive volume for the system temp dir' unless case_insensitive?(out)
          seed_manifest(out, nodes: { '1:2' => 'Mobile/Home__1-2.png', '1:3' => 'Mobile/Cart__1-3.png' })
          seed_file(out, 'Mobile/Home__1-2.png')
          seed_file(out, 'Mobile/Cart__1-3.png')
          stub_figma(pages: [page('mobile', frame('1:2', 'home'), frame('1:3', 'Cart'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(result.stderr).to include('(deleted 0 stale)')
          expect(Dir.children(out).sort).to eq(%w[.figma-sync.json mobile])
          expect(Dir.children(File.join(out, 'mobile')).sort).to eq(%w[Cart__1-3.png home__1-2.png])
          expect(File.read(File.join(out, 'mobile/home__1-2.png'))).to eq('image from https://images.example/1:2')
          expect(read_manifest(out)['version']).to eq('v2')
          expect(manifest_paths(out)).to eq('1:2' => 'mobile/home__1-2.png', '1:3' => 'mobile/Cart__1-3.png')
        end
      end
    end

    context 'when only the case of a frame changed on a case-sensitive volume' do
      it 'writes the new path and removes the old one' do
        spec_tmpdir do |out|
          skip 'needs a case-sensitive volume for spec/tmp' if case_insensitive?(out)
          seed_manifest(out, nodes: { '1:2' => 'Mobile/Home__1-2.png' })
          seed_file(out, 'Mobile/Home__1-2.png')
          stub_figma(pages: [page('Mobile', frame('1:2', 'home'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include('(deleted 1 stale)')
          expect(files_under(out)).to eq(%w[.figma-sync.json Mobile/home__1-2.png])
        end
      end
    end

    context 'when a frame renders nothing' do
      it 'skips it without retrying and still records the version' do
        Dir.mktmpdir do |out|
          stub_figma(pages: [page('P', frame('1:1', 'A'), frame('1:4', 'Empty'))], images: { '1:4' => nil })
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(waits).to eq([])
          expect(result.stderr).to include('1 frame(s) rendered nothing and were skipped: 1:4')
          expect(read_manifest(out)['version']).to eq('v2')
          expect(manifest_paths(out)).to eq('1:1' => 'P/A__1-1.png')
        end
      end
    end

    context 'when a previously exported frame now renders nothing' do
      it 'removes its old file and manifest entry' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:4' => 'P/Card__1-4.png' })
          seed_file(out, 'P/Card__1-4.png')
          stub_figma(pages: [page('P', frame('1:4', 'Card'))], images: { '1:4' => nil })

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.stderr).to include("1 frame(s) rendered nothing and were skipped: 1:4\n    removed P/Card__1-4.png\n")
          expect(files_under(out)).to eq(%w[.figma-sync.json])
          expect(read_manifest(out)).to include('version' => 'v2', 'nodes' => {})
        end
      end
    end

    context 'when the output folder is synced from another file' do
      it 'refuses to touch it and exits 1' do
        Dir.mktmpdir do |out|
          seed_manifest(out, file_key: 'OtherKey', nodes: { '1:1' => 'P/A__1-1.png' })
          seed_file(out, 'P/A__1-1.png')
          client = stub_figma(pages: [page('P', frame('1:9', 'Z'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to eq("figma-sync: #{out} is synced from file OtherKey, not SimKey\n")
          expect(client).not_to have_received(:image_urls)
          expect(files_under(out)).to include('P/A__1-1.png')
        end
      end
    end

    context 'when the manifest is valid JSON but not an object' do
      it 'exits 1 asking to fix or delete it' do
        Dir.mktmpdir do |out|
          File.write(File.join(out, '.figma-sync.json'), '[]')
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to eq("figma-sync: #{out}/.figma-sync.json is not a valid figma-sync manifest; fix or delete it\n")
        end
      end
    end

    context 'when the manifest was written by a newer version of the script' do
      it 'exits 1 asking to upgrade' do
        Dir.mktmpdir do |out|
          File.write(File.join(out, '.figma-sync.json'), JSON.generate('fileKey' => 'SimKey', 'manifestVersion' => 3, 'nodes' => {}))
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to eq("figma-sync: #{out}/.figma-sync.json was written by a newer figma-sync " \
                                      "(manifestVersion 3); upgrade this copy of the script\n")
        end
      end
    end

    context 'when the manifest is not JSON' do
      it 'exits 1 asking to fix or delete it' do
        Dir.mktmpdir do |out|
          File.write(File.join(out, '.figma-sync.json'), '{"nodes":')
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to include('is not a valid figma-sync manifest; fix or delete it')
        end
      end
    end

    context 'when the manifest nodes are not a map of paths' do
      it 'exits 1 asking to fix or delete it' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '1:1' => 5 })
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to include('is not a valid figma-sync manifest')
        end
      end
    end

    context 'when a manifest path points outside the output folder' do
      it 'does not delete it and warns' do
        Dir.mktmpdir do |parent|
          out = File.join(parent, 'mirror')
          victim = File.join(parent, 'victim.txt')
          File.write(victim, 'keep me')
          seed_manifest(out, nodes: { '9:9' => '../victim.txt', '9:8' => victim })
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(File.read(victim)).to eq('keep me')
          expect(result.stderr).to include(%(warning: not deleting "../victim.txt"; it is outside #{out}),
                                           %(warning: not deleting "#{victim}"; it is outside #{out}))
          expect(manifest_paths(out)).to eq('1:1' => 'P/A__1-1.png')
        end
      end
    end

    context 'when the run aborts before stale files are deleted' do
      it 'keeps their manifest entries so a later run can delete them' do
        Dir.mktmpdir do |out|
          seed_manifest(out, nodes: { '9:9' => 'Old/Gone__9-9.png' })
          seed_file(out, 'Old/Gone__9-9.png')
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          allow(client).to receive(:image_urls).and_raise(FigmaSync::AuthError, 'Figma API returned HTTP 403 (Invalid token)')

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr).to end_with("figma-sync: Figma API returned HTTP 403 (Invalid token)\n")
          expect(files_under(out)).to include('Old/Gone__9-9.png')
          expect(read_manifest(out)['version']).to be_nil
          expect(manifest_paths(out)).to eq('9:9' => 'Old/Gone__9-9.png')
        end
      end
    end

    context 'when the images request fails with a transient error' do
      it 'retries the batch with 5s and 15s backoff and then succeeds' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          flaky = [->(*, **) { raise FigmaSync::TransientError, 'GET /v1/images/SimKey returned HTTP 503' }] * 2
          allow(client).to receive(:image_urls).and_invoke(*flaky, ->(*, **) { { '1:1' => 'https://images.example/1:1' } })
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(0)
          expect(waits).to eq([5, 15])
          expect(result.stderr).to include('    retrying 1 frame(s) in 5s (GET /v1/images/SimKey returned HTTP 503)')
        end
      end
    end

    context 'when the images request is rate limited with Retry-After' do
      it 'waits the requested time before retrying' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          limited = ->(*, **) { raise FigmaSync::TransientError.new('HTTP 429', 7) }
          allow(client).to receive(:image_urls).and_invoke(limited, ->(*, **) { { '1:1' => 'https://images.example/1:1' } })
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(waits).to eq([7])
        end
      end
    end

    context 'when the images request keeps failing with a transient error' do
      it 'gives up after three retries and exits 1' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          allow(client).to receive(:image_urls).and_raise(FigmaSync::TransientError, 'HTTP 502')
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(waits).to eq([5, 15, 45])
          expect(result.stderr).to include('    failed after retries: 1:1 (HTTP 502)')
        end
      end
    end

    context 'when the images request fails with a permanent 4xx' do
      it 'fails the batch without retrying' do
        Dir.mktmpdir do |out|
          client = stub_figma(pages: [page('P', frame('1:1', 'A'))])
          allow(client).to receive(:image_urls)
            .and_raise(FigmaSync::SyncError, 'GET /v1/images/SimKey returned HTTP 400 (bad ids)')
          waits = []
          allow(described_class).to receive(:sleep) { |seconds| waits << seconds }

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(waits).to eq([])
          expect(client).to have_received(:image_urls).once
        end
      end
    end

    context 'when a local filesystem error escapes the export' do
      it 'prints one line and exits 1' do
        Dir.mktmpdir do |parent|
          out = File.join(parent, 'mirror')
          File.write(out, 'a file where the folder should be')
          stub_figma(pages: [page('P', frame('1:1', 'A'))])

          result = run_cli('SimKey', '--token', 'tok', '--out', out)

          expect(result.code).to eq(1)
          expect(result.stderr.lines.last).to match(/\Afigma-sync: File exists @ dir_s_mkdir - .*mirror\n\z/)
        end
      end
    end

    context 'when interrupted' do
      it 'exits 130' do
        client = stub_figma(pages: [])
        allow(client).to receive(:get_file).and_raise(Interrupt)

        result = run_cli('SimKey', '--token', 'tok', '--out', 'unused')

        expect(result.code).to eq(130)
        expect(result.stderr).to eq("figma-sync: interrupted\n")
      end
    end

    context 'when no token can be found' do
      it 'exits 1 with the no-token message' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('')
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

        result = run_cli('SimKey', '--dry-run')

        expect(result.code).to eq(1)
        expect(result.stderr).to eq("figma-sync: #{FigmaSync::NO_TOKEN}\n")
      end
    end
  end
end
