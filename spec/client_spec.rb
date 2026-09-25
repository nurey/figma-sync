# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync::Client do
  describe '#get_file' do
    context 'when the API answers 200' do
      it 'sends the token header and depth, and returns the parsed JSON' do
        serve_http([200, {}, '{"name":"Sim","version":"v9"}']) do |base, requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          file = described_class.new('tok').get_file('SimKey', depth: 4)

          expect(file).to eq('name' => 'Sim', 'version' => 'v9')
          expect(requests.first[:line]).to eq('GET /v1/files/SimKey?depth=4 HTTP/1.1')
          expect(requests.first[:headers]['x-figma-token']).to eq('tok')
        end
      end
    end

    context 'when the locale is US-ASCII and the body has non-ASCII characters' do
      it 'parses the body as UTF-8' do
        serve_http([200, { 'Content-Type' => 'application/json' }, '{"name":"Café 🟡"}'.b]) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          file = with_default_external(Encoding::US_ASCII) { described_class.new('tok').get_file('SimKey', depth: 1) }

          expect(file['name']).to eq('Café 🟡')
          expect(file['name'].encoding).to eq(Encoding::UTF_8)
        end
      end
    end

    context 'when the locale is US-ASCII and an error body has non-ASCII characters' do
      it 'includes the decoded error in the message' do
        serve_http([404, {}, '{"err":"Fichier introuvable é"}'.b]) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          with_default_external(Encoding::US_ASCII) do
            expect { described_class.new('tok').get_file('SimKey', depth: 1) }
              .to raise_error(FigmaSync::SyncError, 'GET /v1/files/SimKey returned HTTP 404 (Fichier introuvable é)')
          end
        end
      end
    end

    context 'when rate limited with Retry-After: 7' do
      it 'waits 7s and retries' do
        serve_http([429, { 'Retry-After' => '7' }, '{}'], [200, {}, '{"version":"v9"}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)
          waits = []
          allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

          file = nil
          expect { file = described_class.new('tok').get_file('SimKey', depth: 1) }
            .to output("    retrying file SimKey in 7s (GET /v1/files/SimKey returned HTTP 429)\n").to_stderr

          expect(waits).to eq([7])
          expect(file).to eq('version' => 'v9')
        end
      end
    end

    context 'when rate limited with Retry-After: 0' do
      it 'uses the normal 5s backoff' do
        serve_http([429, { 'Retry-After' => '0' }, '{}'], [200, {}, '{}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)
          waits = []
          allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

          expect { described_class.new('tok').get_file('SimKey', depth: 1) }.to output.to_stderr

          expect(waits).to eq([5])
        end
      end
    end

    context 'when rate limited with a Retry-After above the cap' do
      it 'waits at most 120s' do
        serve_http([429, { 'Retry-After' => '999' }, '{}'], [200, {}, '{}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)
          waits = []
          allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

          expect { described_class.new('tok').get_file('SimKey', depth: 1) }.to output.to_stderr

          expect(waits).to eq([120])
        end
      end
    end

    context 'when rate limited without Retry-After' do
      it 'uses the normal 5s backoff' do
        serve_http([429, {}, '{}'], [200, {}, '{}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)
          waits = []
          allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

          expect { described_class.new('tok').get_file('SimKey', depth: 1) }.to output.to_stderr

          expect(waits).to eq([5])
        end
      end
    end

    context 'when the API keeps answering 5xx' do
      it 'retries three times with 5/15/45s backoff and then raises' do
        responses = [[500, {}, ''], [502, {}, ''], [503, {}, ''], [504, {}, '']]
        serve_http(*responses) do |base, requests|
          stub_const('FigmaSync::Client::API_BASE', base)
          waits = []
          allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

          expect { described_class.new('tok').get_file('SimKey', depth: 1) }
            .to raise_error(FigmaSync::TransientError, 'GET /v1/files/SimKey returned HTTP 504')
            .and output(/retrying file SimKey in 45s/).to_stderr

          expect(waits).to eq([5, 15, 45])
          expect(requests.size).to eq(4)
        end
      end
    end

    context 'when the API answers a permanent 4xx' do
      it 'raises without retrying and includes the API error' do
        serve_http([404, {}, '{"status":404,"err":"Not found"}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)
          waits = []
          allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

          expect { described_class.new('tok').get_file('SimKey', depth: 1) }
            .to raise_error(FigmaSync::SyncError, 'GET /v1/files/SimKey returned HTTP 404 (Not found)')

          expect(waits).to eq([])
        end
      end
    end

    context 'when the API answers 403' do
      it 'raises an AuthError that does not echo the token' do
        serve_http([403, {}, '{"status":403,"err":"Invalid token"}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          expect { described_class.new('figd_SECRET').get_file('SimKey', depth: 1) }
            .to raise_error(FigmaSync::AuthError) { |error|
              expect(error.message).to eq('Figma API returned HTTP 403 (Invalid token): ' \
                                          'the token is invalid or lacks access to this file')
              expect(error.message).not_to include('SECRET')
            }
        end
      end
    end

    context 'when the API answers 200 with a body that is not JSON' do
      it 'raises a SyncError' do
        serve_http([200, {}, '<html>']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          expect { described_class.new('tok').get_file('SimKey', depth: 1) }
            .to raise_error(FigmaSync::SyncError, 'GET /v1/files/SimKey returned non-JSON output')
        end
      end
    end

    context 'when the API cannot be reached' do
      it 'retries as a network error and then raises' do
        stub_const('FigmaSync::Client::API_BASE', "http://127.0.0.1:#{closed_port}")
        waits = []
        allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

        expect { described_class.new('tok').get_file('SimKey', depth: 1) }
          .to raise_error(FigmaSync::TransientError, /\A127\.0\.0\.1: .*\(Errno::ECONNREFUSED\)\z/)
          .and output(/retrying file SimKey in 5s/).to_stderr

        expect(waits).to eq([5, 15, 45])
      end
    end
  end

  describe '#node_documents' do
    context 'when the API answers with node subtrees' do
      it 'requests the ids and returns each document, nil for deleted nodes' do
        body = '{"nodes":{"1:1":{"document":{"id":"1:1","children":[]},"components":{}},"1:2":null}}'
        serve_http([200, {}, body]) do |base, requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          documents = described_class.new('tok').node_documents('SimKey', %w[1:1 1:2])

          expect(documents).to eq('1:1' => { 'id' => '1:1', 'children' => [] }, '1:2' => nil)
          expect(requests.first[:line]).to eq('GET /v1/files/SimKey/nodes?ids=1%3A1%2C1%3A2&geometry=paths HTTP/1.1')
        end
      end
    end
  end

  describe '#node_documents with deep subtrees' do
    context 'when a subtree is nested more than 100 levels deep' do
      it 'parses it' do
        deep = (1..150).reduce({ 'id' => 'leaf' }) { |child, i| { 'id' => "g#{i}", 'children' => [child] } }
        body = JSON.generate({ 'nodes' => { '1:1' => { 'document' => deep } } }, max_nesting: false)
        serve_http([200, {}, body]) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          documents = described_class.new('tok').node_documents('SimKey', %w[1:1])

          expect(documents['1:1']['id']).to eq('g150')
        end
      end
    end
  end

  describe 'read timeouts' do
    context 'when the server accepts but never answers' do
      it 'raises a TransientError caused by Net::ReadTimeout' do
        server = TCPServer.new('127.0.0.1', 0)
        held = []
        acceptor = Thread.new { loop { held << server.accept } }
        stub_const('FigmaSync::Client::API_BASE', "http://127.0.0.1:#{server.addr[1]}")
        stub_const('FigmaSync::Client::READ_TIMEOUT', 0.2)

        expect { described_class.new('tok').node_documents('SimKey', %w[1:1]) }
          .to raise_error(FigmaSync::TransientError) { |error| expect(error.cause).to be_a(Net::ReadTimeout) }
      ensure
        acceptor&.kill
        held&.each(&:close)
        server&.close
      end
    end
  end

  describe 'connection reuse' do
    context 'when two API calls go to the same host' do
      it 'sends both over one kept-alive connection' do
        serve_keep_alive('{"version":"v1"}', '{"version":"v1"}') do |base, stats|
          stub_const('FigmaSync::Client::API_BASE', base)
          client = described_class.new('tok')

          client.get_file('SimKey', depth: 1)
          client.get_file('SimKey', depth: 4)

          expect(stats[:requests]).to eq(['/v1/files/SimKey?depth=1', '/v1/files/SimKey?depth=4'])
          expect(stats[:connections]).to eq(1)
        end
      end
    end

    context 'when two images are downloaded from the same host' do
      it 'sends both over one kept-alive connection' do
        serve_keep_alive('png one', 'png two') do |base, stats|
          Dir.mktmpdir do |dir|
            client = described_class.new('tok')

            client.download("#{base}/a.png", File.join(dir, 'a.png'))
            client.download("#{base}/b.png", File.join(dir, 'b.png'))

            expect(File.read(File.join(dir, 'b.png'))).to eq('png two')
            expect(stats[:connections]).to eq(1)
          end
        end
      end
    end
  end

  describe '#image_urls' do
    context 'when the API answers with images' do
      it 'requests ids, format and scale and returns the id => url map' do
        body = '{"err":null,"images":{"1:1":"https://s3.example/a.png","1:2":null}}'
        serve_http([200, {}, body]) do |base, requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          urls = described_class.new('tok').image_urls('SimKey', %w[1:1 1:2], fmt: 'png', scale: 2.0)

          expect(urls).to eq('1:1' => 'https://s3.example/a.png', '1:2' => nil)
          expect(requests.first[:line]).to eq('GET /v1/images/SimKey?ids=1%3A1%2C1%3A2&format=png&scale=2 HTTP/1.1')
        end
      end
    end

    context 'when the API answers 200 with an err' do
      it 'raises a SyncError' do
        serve_http([200, {}, '{"err":"Render timeout","images":{}}']) do |base, _requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          expect { described_class.new('tok').image_urls('SimKey', %w[1:1], fmt: 'png', scale: 1.5) }
            .to raise_error(FigmaSync::SyncError, 'images request failed: Render timeout')
        end
      end
    end

    context 'when the API answers 5xx' do
      it 'raises a TransientError without retrying, leaving retries to the batch' do
        serve_http([503, {}, '']) do |base, requests|
          stub_const('FigmaSync::Client::API_BASE', base)

          expect { described_class.new('tok').image_urls('SimKey', %w[1:1], fmt: 'png', scale: 2.0) }
            .to raise_error(FigmaSync::TransientError, 'GET /v1/images/SimKey returned HTTP 503')
          expect(requests.size).to eq(1)
        end
      end
    end
  end

  describe '#download' do
    context 'when the image URL redirects' do
      it 'follows it, writes the body to dest and never sends the token' do
        serve_http([302, { 'Location' => '/final.png' }, ''], [200, {}, "\x89PNG-bytes"]) do |base, requests|
          Dir.mktmpdir do |dir|
            dest = File.join(dir, 'Page', 'Frame__1-1.png')

            described_class.new('figd_SECRET').download("#{base}/start.png", dest)

            expect(File.binread(dest)).to eq("\x89PNG-bytes".b)
            expect(requests.map { |r| r[:line] }).to eq(['GET /start.png HTTP/1.1', 'GET /final.png HTTP/1.1'])
            expect(requests.map { |r| r[:headers]['x-figma-token'] }).to eq([nil, nil])
            expect(Dir.children(File.join(dir, 'Page'))).to eq(['Frame__1-1.png'])
          end
        end
      end
    end

    context 'when the image host answers 5xx once' do
      it 'retries after 5s' do
        serve_http([503, {}, ''], [200, {}, 'png']) do |base, _requests|
          Dir.mktmpdir do |dir|
            waits = []
            allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

            expect { described_class.new('tok').download("#{base}/a.png", File.join(dir, 'a.png')) }
              .to output("    retrying download a.png in 5s (download from 127.0.0.1 returned HTTP 503)\n").to_stderr

            expect(waits).to eq([5])
            expect(File.read(File.join(dir, 'a.png'))).to eq('png')
          end
        end
      end
    end

    context 'when the image host answers 403 for an expired URL' do
      it 'raises a SyncError, not an AuthError, and leaves no partial file' do
        serve_http([403, {}, 'expired']) do |base, _requests|
          Dir.mktmpdir do |dir|
            expect { described_class.new('tok').download("#{base}/a.png", File.join(dir, 'a.png')) }
              .to raise_error(FigmaSync::SyncError, 'download from 127.0.0.1 returned HTTP 403') { |error|
                expect(error).not_to be_a(FigmaSync::AuthError)
              }
            expect(Dir.children(dir)).to eq([])
          end
        end
      end
    end

    context 'when the destination folder is not writable' do
      it 'raises a SyncError with the path and does not retry' do
        serve_http([200, {}, 'png']) do |base, _requests|
          Dir.mktmpdir do |dir|
            locked = File.join(dir, 'Page')
            Dir.mkdir(locked, 0o500)
            waits = []
            allow(FigmaSync).to receive(:sleep) { |seconds| waits << seconds }

            expect { described_class.new('tok').download("#{base}/a.png", File.join(locked, 'a.png')) }
              .to raise_error(FigmaSync::SyncError, %r{\APermission denied @ rb_sysopen - #{Regexp.escape(locked)}/\.a\.png\.part\z})

            expect(waits).to eq([])
          ensure
            File.chmod(0o700, locked)
          end
        end
      end
    end

    context 'when a file blocks the destination folder' do
      it 'raises a SyncError before downloading anything' do
        serve_http do |base, requests|
          Dir.mktmpdir do |dir|
            File.write(File.join(dir, 'Page'), 'not a folder')

            expect { described_class.new('tok').download("#{base}/a.png", File.join(dir, 'Page', 'a.png')) }
              .to raise_error(FigmaSync::SyncError, /File exists @ dir_s_mkdir - .*Page\z/)
            expect(requests).to eq([])
          end
        end
      end
    end
  end
end
