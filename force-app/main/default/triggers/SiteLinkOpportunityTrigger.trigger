trigger SiteLinkOpportunityTrigger on Opportunity(before insert, before update, after insert, after update) {
    SiteLinkTriggerHandler.handle();
}
