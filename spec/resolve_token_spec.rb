# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  describe '.resolve_token' do
    context 'when a --token value is given' do
      it 'uses it without consulting FIGMA_TOKEN or the keychain' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('from-env')
        allow(Open3).to receive(:capture3)

        token = described_class.resolve_token('  from-flag  ')

        expect(token).to eq('from-flag')
        expect(Open3).not_to have_received(:capture3)
      end
    end

    context 'when only FIGMA_TOKEN is set' do
      it 'uses the environment variable' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return("from-env\n")
        allow(Open3).to receive(:capture3)

        expect(described_class.resolve_token(nil)).to eq('from-env')
        expect(Open3).not_to have_received(:capture3)
      end
    end

    context 'when neither the flag nor FIGMA_TOKEN is set' do
      it 'reads the figma-token keychain item' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('')
        status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3)
          .with('security', 'find-generic-password', '-s', 'figma-token', '-w')
          .and_return(["from-keychain\n", '', status])

        expect(described_class.resolve_token(nil)).to eq('from-keychain')
      end
    end

    context 'when the keychain has no item' do
      it 'raises the no-token message' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('')
        status = instance_double(Process::Status, success?: false)
        allow(Open3).to receive(:capture3).and_return(['', 'item not found', status])

        expect { described_class.resolve_token(nil) }.to raise_error(FigmaSync::SyncError, FigmaSync::NO_TOKEN)
      end
    end

    context 'when the security command is not on PATH' do
      it 'skips the keychain and raises the no-token message' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('')
        allow(Open3).to receive(:capture3).and_raise(Errno::ENOENT)

        expect { described_class.resolve_token(nil) }
          .to raise_error(FigmaSync::SyncError, /\ANo Figma token\. Set FIGMA_TOKEN, pass --token, or store one/)
      end
    end

    context 'when the token contains CR/LF' do
      it 'rejects it without echoing the value' do
        expect { described_class.resolve_token("figd_SECRET\r\nX-Evil: 1") }
          .to raise_error(FigmaSync::SyncError) { |error|
            expect(error.message).to eq(FigmaSync::MALFORMED_TOKEN)
            expect(error.message).not_to include('SECRET')
          }
      end
    end

    context 'when the token contains a control character' do
      it 'rejects it' do
        expect { described_class.resolve_token("figd_\u0001abc") }
          .to raise_error(FigmaSync::SyncError, FigmaSync::MALFORMED_TOKEN)
      end
    end

    context 'when the keychain returns non-ASCII bytes under a US-ASCII locale' do
      it 'rejects the token instead of crashing' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('')
        status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3).and_return([locale_tagged("figd_\u00e9t\u00e9\n"), '', status])

        expect { described_class.resolve_token(nil) }.to raise_error(FigmaSync::SyncError, FigmaSync::MALFORMED_TOKEN)
      end
    end

    context 'when FIGMA_TOKEN holds non-ASCII bytes under a US-ASCII locale' do
      it 'rejects the token instead of crashing' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return(locale_tagged('figd_é'))

        expect { described_class.resolve_token(nil) }.to raise_error(FigmaSync::SyncError, FigmaSync::MALFORMED_TOKEN)
      end
    end

    context 'when the keychain token contains inner whitespace' do
      it 'rejects it' do
        allow(ENV).to receive(:fetch).and_call_original
        allow(ENV).to receive(:fetch).with('FIGMA_TOKEN', '').and_return('')
        status = instance_double(Process::Status, success?: true)
        allow(Open3).to receive(:capture3).and_return(["figd_a b\n", '', status])

        expect { described_class.resolve_token(nil) }.to raise_error(FigmaSync::SyncError, FigmaSync::MALFORMED_TOKEN)
      end
    end
  end
end
