const { expect } = require("chai");
const { ethers } = require("hardhat");
const { time } = require("@nomicfoundation/hardhat-network-helpers");

describe("RentalAgreement", () => {
  const rent = ethers.parseEther("1"), dep = ethers.parseEther("2");
  let c, owner, tenant, arb, other, end;

  beforeEach(async () => {
    [owner, tenant, arb, other] = await ethers.getSigners();
    c = await (await ethers.getContractFactory("RentalAgreement")).deploy();
    await c.connect(owner).registerProperty("Room 101", rent, dep);
    const now = await time.latest();
    end = now + 90 * 86400;
    await c.connect(owner).createAgreement(0, tenant.address, arb.address, now, end, "no pets");
    await c.connect(owner).confirmAgreement(0);
    await c.connect(tenant).confirmAgreement(0);
    await c.connect(tenant).depositSecurity(0, { value: dep });
  });

  it("enforces roles and exact amounts", async () => {
    await expect(c.connect(other).confirmAgreement(0)).to.be.reverted;
    await expect(c.connect(tenant).payRent(0, { value: rent - 1n })).to.be.revertedWith("bad sender/amount");
    await expect(c.connect(other).createAgreement(0, tenant.address, arb.address, 1, end, "")).to.be.revertedWith("not owner");
  });

  it("records rent payments", async () => {
    await c.connect(tenant).payRent(0, { value: rent });
    const p = await c.getPayments(0);
    expect(p.length).to.equal(1);
    expect(p[0].amount).to.equal(rent);
  });

  it("cannot deduct before lease end or beyond deposit", async () => {
    await expect(c.connect(owner).proposeDeduction(0, 1, "x")).to.be.revertedWith("lease not ended");
    await time.increaseTo(end);
    await expect(c.connect(owner).proposeDeduction(0, dep + 1n, "x")).to.be.revertedWith("exceeds deposit");
    await expect(c.connect(owner).proposeDeduction(0, 1, "")).to.be.revertedWith("reason required");
  });

  it("full refund when no deduction", async () => {
    await time.increaseTo(end);
    await c.connect(owner).proposeDeduction(0, 0, "");
    await expect(c.connect(tenant).withdraw()).to.changeEtherBalance(tenant, dep);
  });

  it("accepted deduction splits deposit", async () => {
    await time.increaseTo(end);
    const d = ethers.parseEther("0.5");
    await c.connect(owner).proposeDeduction(0, d, "broken window");
    await c.connect(tenant).acceptDeduction(0);
    await expect(c.connect(owner).withdraw()).to.changeEtherBalance(owner, d);
    await expect(c.connect(tenant).withdraw()).to.changeEtherBalance(tenant, dep - d);
    await expect(c.connect(tenant).withdraw()).to.be.revertedWith("nothing");
  });

  it("dispute is decided by arbiter only", async () => {
    await time.increaseTo(end);
    await c.connect(owner).proposeDeduction(0, dep, "damage");
    await c.connect(tenant).disputeDeduction(0, "not true");
    await expect(c.connect(owner).resolveDispute(0, dep, "")).to.be.revertedWith("not allowed");
    await c.connect(arb).resolveDispute(0, ethers.parseEther("0.2"), "minor wear");
    await expect(c.connect(tenant).withdraw()).to.changeEtherBalance(tenant, ethers.parseEther("1.8"));
  });

  it("either party cancels only before the deposit is paid", async () => {
    await c.connect(owner).createAgreement(0, tenant.address, arb.address, await time.latest(), end, "");
    await expect(c.connect(other).cancelAgreement(1)).to.be.revertedWith("not party");
    await c.connect(tenant).cancelAgreement(1);
    await expect(c.connect(tenant).confirmAgreement(1)).to.be.revertedWith("not open");
    await expect(c.connect(owner).cancelAgreement(1)).to.be.revertedWith("cannot cancel");
    // agreement 0 already holds the deposit
    await expect(c.connect(owner).cancelAgreement(0)).to.be.revertedWith("cannot cancel");
  });

  it("owner cancels a confirmed agreement whose tenant never deposits", async () => {
    await c.connect(owner).createAgreement(0, tenant.address, arb.address, await time.latest(), end, "");
    await c.connect(owner).confirmAgreement(1);
    await c.connect(tenant).confirmAgreement(1);
    await c.connect(owner).cancelAgreement(1);
    await expect(c.connect(tenant).depositSecurity(1, { value: dep })).to.be.revertedWith("cannot deposit");
  });

  describe("timeouts: silence never locks the deposit", () => {
    const WINDOW = 14 * 86400;

    it("tenant reclaims full deposit if owner never settles", async () => {
      await time.increaseTo(end + WINDOW - 10);
      await expect(c.connect(tenant).claimTimeout(0)).to.be.revertedWith("too early");
      await time.increaseTo(end + WINDOW);
      await expect(c.connect(owner).claimTimeout(0)).to.be.revertedWith("not allowed");
      await c.connect(tenant).claimTimeout(0);
      await expect(c.connect(tenant).withdraw()).to.changeEtherBalance(tenant, dep);
      await expect(c.connect(owner).proposeDeduction(0, 1, "late")).to.be.revertedWith("not allowed");
    });

    it("owner closes with proposed deduction if tenant never answers", async () => {
      await time.increaseTo(end);
      const d = ethers.parseEther("0.5");
      await c.connect(owner).proposeDeduction(0, d, "broken window");
      await expect(c.connect(owner).claimTimeout(0)).to.be.revertedWith("too early");
      await time.increase(WINDOW);
      await expect(c.connect(tenant).claimTimeout(0)).to.be.revertedWith("not allowed");
      await c.connect(owner).claimTimeout(0);
      await expect(c.connect(owner).withdraw()).to.changeEtherBalance(owner, d);
      await expect(c.connect(tenant).withdraw()).to.changeEtherBalance(tenant, dep - d);
    });

    it("full refund if arbiter never rules", async () => {
      await time.increaseTo(end);
      await c.connect(owner).proposeDeduction(0, dep, "damage");
      await c.connect(tenant).disputeDeduction(0, "not true");
      await expect(c.connect(tenant).claimTimeout(0)).to.be.revertedWith("too early");
      await time.increase(WINDOW);
      await expect(c.connect(arb).claimTimeout(0)).to.be.revertedWith("not allowed");
      await c.connect(owner).claimTimeout(0);
      await expect(c.connect(tenant).withdraw()).to.changeEtherBalance(tenant, dep);
      await expect(c.connect(arb).resolveDispute(0, dep, "late")).to.be.revertedWith("not allowed");
    });
  });
});
