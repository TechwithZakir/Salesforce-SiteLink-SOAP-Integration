import { createElement } from "lwc";
import SiteLinkPush, { errorMessage } from "c/siteLinkPush";
import getStatus from "@salesforce/apex/SiteLinkController.getStatus";
import pushToSiteLink from "@salesforce/apex/SiteLinkController.pushToSiteLink";
import refreshFromSiteLink from "@salesforce/apex/SiteLinkController.refreshFromSiteLink";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
const SHOW_TOAST = "lightning__showtoast";

jest.mock("@salesforce/apex/SiteLinkController.getStatus", () => ({ default: jest.fn() }), { virtual: true });
jest.mock("@salesforce/apex/SiteLinkController.pushToSiteLink", () => ({ default: jest.fn() }), { virtual: true });
jest.mock("@salesforce/apex/SiteLinkController.refreshFromSiteLink", () => ({ default: jest.fn() }), { virtual: true });
jest.mock("lightning/uiRecordApi", () => ({ notifyRecordUpdateAvailable: jest.fn(() => Promise.resolve()) }), { virtual: true });

const OPP_ID = "006000000000001AAA";

const notSynced = {
    objectType: "Opportunity",
    status: "Not Synced",
    canPush: true,
    integrationActive: true,
    storeName: "Calgary North",
    unitName: "A101"
};

const synced = {
    ...notSynced,
    status: "Synced",
    message: "In sync with SiteLink.",
    tenantId: 101,
    reservationId: 555,
    customerStatus: "Synced",
    lastSynced: "2026-10-22T10:00:00.000Z"
};

// eslint-disable-next-line @lwc/lwc/no-async-operation
const flush = () => new Promise((resolve) => setTimeout(resolve, 0));

async function render(status) {
    getStatus.mockResolvedValue(status);
    const element = createElement("c-site-link-push", { is: SiteLinkPush });
    element.recordId = OPP_ID;
    document.body.appendChild(element);
    await flush();
    return element;
}

const byId = (element, id) => element.shadowRoot.querySelector(`[data-id="${id}"]`);

describe("c-site-link-push", () => {
    afterEach(() => {
        while (document.body.firstChild) {
            document.body.removeChild(document.body.firstChild);
        }
        jest.clearAllMocks();
    });

    it("loads and shows the current sync status", async () => {
        const element = await render(synced);
        expect(getStatus).toHaveBeenCalledWith({ recordId: OPP_ID });
        expect(byId(element, "status").textContent).toBe("Synced");
        expect(byId(element, "status").className).toContain("slds-theme_success");
        expect(byId(element, "message").textContent).toBe("In sync with SiteLink.");
        expect(byId(element, "tenant").textContent).toBe("101");
        expect(byId(element, "reservation").textContent).toBe("555");
        expect(byId(element, "customer").textContent).toBe("Synced");
        expect(byId(element, "push").disabled).toBe(false);
        expect(byId(element, "refresh").disabled).toBe(false);
    });

    it("pushes, shows a success toast and refreshes the record page", async () => {
        const element = await render(notSynced);
        expect(byId(element, "refresh").disabled).toBe(true);
        pushToSiteLink.mockResolvedValue(synced);
        const toast = jest.fn();
        element.addEventListener(SHOW_TOAST, toast);

        byId(element, "push").click();
        await flush();

        expect(pushToSiteLink).toHaveBeenCalledWith({ recordId: OPP_ID });
        expect(toast).toHaveBeenCalledTimes(1);
        expect(toast.mock.calls[0][0].detail.variant).toBe("success");
        expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([{ recordId: OPP_ID }]);
        expect(byId(element, "status").textContent).toBe("Synced");
    });

    it("warns when the push did not fully succeed", async () => {
        const element = await render(notSynced);
        pushToSiteLink.mockResolvedValue({ ...notSynced, status: "Retrying", message: "SiteLink took too long to answer." });
        const toast = jest.fn();
        element.addEventListener(SHOW_TOAST, toast);

        byId(element, "push").click();
        await flush();

        expect(toast.mock.calls[0][0].detail.variant).toBe("warning");
        expect(toast.mock.calls[0][0].detail.message).toBe("SiteLink took too long to answer.");
        expect(byId(element, "status").className).toContain("slds-theme_warning");
    });

    it("shows server errors as an error toast", async () => {
        const element = await render(synced);
        refreshFromSiteLink.mockRejectedValue({ body: { message: "SiteLink rejected the integration login." } });
        const toast = jest.fn();
        element.addEventListener(SHOW_TOAST, toast);

        byId(element, "refresh").click();
        await flush();

        expect(refreshFromSiteLink).toHaveBeenCalledWith({ recordId: OPP_ID });
        expect(toast.mock.calls[0][0].detail.variant).toBe("error");
        expect(toast.mock.calls[0][0].detail.message).toBe("SiteLink rejected the integration login.");
        expect(byId(element, "push").disabled).toBe(false);
    });

    it("explains why the push button is disabled", async () => {
        const element = await render({ ...notSynced, canPush: false });
        expect(byId(element, "push").disabled).toBe(true);
        expect(byId(element, "hint").textContent).toContain("Choose a SiteLink store");

        const off = await render({ ...notSynced, integrationActive: false });
        expect(byId(off, "hint").textContent).toContain("switched off");
    });

    it("shows a load error", async () => {
        getStatus.mockRejectedValue({ body: [{ message: "No access" }] });
        const element = createElement("c-site-link-push", { is: SiteLinkPush });
        element.recordId = OPP_ID;
        document.body.appendChild(element);
        await flush();
        expect(byId(element, "error").textContent).toBe("No access");
    });

    it("formats every error shape", () => {
        expect(errorMessage(undefined)).toBe("Unknown error");
        expect(errorMessage({ body: { message: "a" } })).toBe("a");
        expect(errorMessage({ body: [{ message: "a" }, { message: "b" }] })).toBe("a, b");
        expect(errorMessage(new Error("boom"))).toBe("boom");
    });
});
