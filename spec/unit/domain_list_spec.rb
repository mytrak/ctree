# frozen_string_literal: true

RSpec.describe "Ctree::Domain.list" do
  let(:conf_path) { "/tmp/fake-dnsmasq.conf" }

  before do
    allow(Ctree::Domain).to receive(:macos?).and_return(true)
    allow(Ctree::Domain).to receive(:find_dnsmasq!).and_return(["dns", conf_path, "53"])
  end

  context "when the conf has configured address entries" do
    before do
      allow(Ctree::Domain).to receive(:read_conf).and_return([
        "address=/.docker/127.0.0.1\n",
        "address=/.myapp/127.0.0.1\n",
        "server=8.8.8.8\n"
      ])
      allow(File).to receive(:exist?).with("/etc/resolver/docker").and_return(true)
      allow(File).to receive(:exist?).with("/etc/resolver/myapp").and_return(false)
    end

    it "prints each TLD with resolver ok status" do
      expect { Ctree::Domain.list }.to output(/docker\s+\(resolver: ok\)/).to_stdout
    end

    it "prints each TLD with resolver missing status" do
      expect { Ctree::Domain.list }.to output(/myapp\s+\(resolver: missing\)/).to_stdout
    end

    it "ignores non-address lines" do
      expect { Ctree::Domain.list }.not_to output(/8\.8\.8\.8/).to_stdout
    end
  end

  context "when the conf has no address entries" do
    before do
      allow(Ctree::Domain).to receive(:read_conf).and_return([])
    end

    it "reports no domains configured" do
      expect { Ctree::Domain.list }.to output(/no domains configured/).to_stdout
    end
  end

  context "when not running on macOS" do
    before do
      allow(Ctree::Domain).to receive(:macos?).and_return(false)
    end

    it "exits 1 with a macOS-only notice for list" do
      expect { Ctree::Domain.list }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/macOS/).to_stderr
    end

    it "exits 1 with a macOS-only notice for add" do
      expect { Ctree::Domain.add(tld: "docker") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/macOS/).to_stderr
    end

    it "exits 1 with a macOS-only notice for remove" do
      expect { Ctree::Domain.remove(tld: "docker") }
        .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
        .and output(/macOS/).to_stderr
    end
  end
end
