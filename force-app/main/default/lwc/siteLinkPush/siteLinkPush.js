import { LightningElement, api } from "lwc";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { notifyRecordUpdateAvailable } from "lightning/uiRecordApi";
import getStatus from "@salesforce/apex/SiteLinkController.getStatus";
import pushToSiteLink from "@salesforce/apex/SiteLinkController.pushToSiteLink";
import refreshFromSiteLink from "@salesforce/apex/SiteLinkController.refreshFromSiteLink";

const BADGE_CLASS = {
    Synced: "slds-badge slds-theme_success",
    Pending: "slds-badge slds-theme_warning",
    Retrying: "slds-badge slds-theme_warning",
    Failed: "slds-badge slds-theme_error"
};

export function errorMessage(error) {
    if (!error) {
        return "Unknown error";
    }
    if (error.body) {
        if (Array.isArray(error.body)) {
            return error.body.map((e) => e.message).join(", ");
        }
        if (error.body.message) {
            return error.body.message;
        }
    }
    return error.message || String(error);
}

export default class SiteLinkPush extends LightningElement {
    @api recordId;
    sync;
    error;
    busy = false;

    connectedCallback() {
        this.load();
    }

    async load() {
        try {
            this.sync = await getStatus({ recordId: this.recordId });
            this.error = undefined;
        } catch (e) {
            this.error = errorMessage(e);
        }
    }

    get loading() {
        return !this.sync && !this.error;
    }

    get statusLabel() {
        return this.sync?.status || "Not Synced";
    }

    get badgeClass() {
        return BADGE_CLASS[this.statusLabel] || "slds-badge";
    }

    get isOpportunity() {
        return this.sync?.objectType === "Opportunity";
    }

    get showCustomer() {
        return this.isOpportunity && !!this.sync?.customerStatus;
    }

    get pushDisabled() {
        return this.busy || !this.sync?.canPush || !this.sync?.integrationActive;
    }

    get refreshDisabled() {
        return this.busy || !this.sync?.integrationActive || (!this.sync?.tenantId && !this.sync?.reservationId);
    }

    get hint() {
        if (!this.sync) {
            return null;
        }
        if (!this.sync.integrationActive) {
            return "The SiteLink integration is switched off.";
        }
        if (!this.sync.canPush) {
            return this.isOpportunity
                ? "Choose a SiteLink store and a customer to enable the push."
                : "Choose a SiteLink store to enable the push.";
        }
        return null;
    }

    handlePush() {
        return this.run(pushToSiteLink, "Sent to SiteLink");
    }

    handleRefresh() {
        return this.run(refreshFromSiteLink, "Updated from SiteLink");
    }

    async run(action, successTitle) {
        this.busy = true;
        try {
            this.sync = await action({ recordId: this.recordId });
            const ok = this.sync.status === "Synced";
            this.toast(ok ? successTitle : "SiteLink sync needs attention", this.sync.message, ok ? "success" : "warning");
            await notifyRecordUpdateAvailable([{ recordId: this.recordId }]);
        } catch (e) {
            this.toast("SiteLink sync failed", errorMessage(e), "error");
        } finally {
            this.busy = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message: message || "", variant }));
    }
}
