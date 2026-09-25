# frozen_string_literal: true

require 'spec_helper'

RSpec.describe FigmaSync do
  describe '.parse_file_key' do
    context 'when given a /design/ URL' do
      it 'returns the key segment' do
        key = described_class.parse_file_key('https://www.figma.com/design/AB3XezYdAhILPLGy7nEion/R-E?node-id=1-2')

        expect(key).to eq('AB3XezYdAhILPLGy7nEion')
      end
    end

    context 'when given a legacy /file/ URL' do
      it 'returns the key segment' do
        key = described_class.parse_file_key('https://www.figma.com/file/Abc123/Old-name')

        expect(key).to eq('Abc123')
      end
    end

    context 'when given a bare key' do
      it 'returns it unchanged' do
        expect(described_class.parse_file_key('Abc123')).to eq('Abc123')
      end
    end

    context 'when given something that is neither' do
      it 'raises a SyncError naming the input' do
        expect { described_class.parse_file_key('not a key!') }
          .to raise_error(FigmaSync::SyncError, 'cannot parse a Figma file key from "not a key!"')
      end
    end
  end

  describe '.parse_options' do
    context 'when only FILE is given' do
      it 'applies the defaults' do
        options = described_class.parse_options(['Abc123'])

        expect(options).to eq(file: 'Abc123', scale: 2.0, format: 'png', force: false, dry_run: false,
                              limit: nil, out: nil, token: nil)
      end
    end

    context 'when every public option is given' do
      it 'parses each one' do
        argv = %w[Abc123 --out dir --scale 0.5 --format svg --force --dry-run --token tok]

        options = described_class.parse_options(argv)

        expect(options).to include(out: 'dir', scale: 0.5, format: 'svg', force: true, dry_run: true, token: 'tok')
      end
    end

    context 'when the hidden --limit is given' do
      it 'parses it as an integer' do
        expect(described_class.parse_options(%w[Abc123 --limit 3])[:limit]).to eq(3)
      end
    end
  end

  describe '.main argument errors' do
    context 'when --scale is out of range' do
      it 'exits 2 with the reason' do
        result = run_cli('Abc123', '--scale', '9')

        expect(result.code).to eq(2)
        expect(result.stderr).to include('invalid argument: --scale 9.0 (must be between 0.01 and 4)')
      end
    end

    context 'when --format is not a supported format' do
      it 'exits 2' do
        result = run_cli('Abc123', '--format', 'gif')

        expect(result.code).to eq(2)
        expect(result.stderr).to include('invalid argument: --format gif')
      end
    end

    context 'when --limit is below 1' do
      it 'exits 2' do
        result = run_cli('Abc123', '--limit', '0')

        expect(result.code).to eq(2)
        expect(result.stderr).to include('(must be >= 1)')
      end
    end

    context 'when FILE is missing' do
      it 'exits 2 and prints the usage' do
        result = run_cli

        expect(result.code).to eq(2)
        expect(result.stderr).to include('usage: figma-sync [options] FILE', 'missing argument: FILE')
      end
    end

    context 'when more than one FILE is given' do
      it 'exits 2' do
        result = run_cli('Abc123', 'Def456')

        expect(result.code).to eq(2)
        expect(result.stderr).to include('needless argument: Def456')
      end
    end

    context 'when an unknown option is given' do
      it 'exits 2' do
        expect(run_cli('Abc123', '--depth', '4').code).to eq(2)
      end
    end
  end

  describe '.main --help' do
    subject(:print_help) { run_cli('--help') }

    it 'prints the public options and exits 0' do
      print_help

      expect(print_help.code).to eq(0)
      expect(print_help.stdout).to include('--out DIR', '--scale N', '--format FORMAT', '--force', '--dry-run', '--token TOKEN')
    end

    it 'does not list the hidden --limit' do
      expect(print_help.stdout).not_to include('--limit')
    end
  end

  describe '.main --out' do
    context 'when --out starts with ~' do
      it 'expands it and prints it relative to home' do
        name = "figma-sync-spec-#{Process.pid}-#{rand(1_000_000)}"
        stub_figma(pages: [page('P', frame('1:1', 'A'))])

        result = run_cli('SimKey', '--token', 'tok', '--dry-run', '--out', "~/#{name}")

        expect(result.stdout).to start_with("Output: ~/#{name}\n")
        expect(File.exist?(File.join(Dir.home, name))).to be(false)
      end
    end

    context 'when --out is relative' do
      it 'prints it as given' do
        stub_figma(pages: [page('P', frame('1:1', 'A'))])

        result = run_cli('SimKey', '--token', 'tok', '--dry-run', '--out', 'some/relative/dir')

        expect(result.stdout).to start_with("Output: some/relative/dir\n")
      end
    end

    context 'when --out is omitted' do
      it 'defaults to ~/Figma/<sanitized file name>' do
        stub_figma(pages: [page('P', frame('1:1', 'A'))])

        result = run_cli('SimKey', '--token', 'tok', '--dry-run')

        expect(result.stdout).to start_with("Output: ~/Figma/Sim file\n")
      end
    end
  end
end
