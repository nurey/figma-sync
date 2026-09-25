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
