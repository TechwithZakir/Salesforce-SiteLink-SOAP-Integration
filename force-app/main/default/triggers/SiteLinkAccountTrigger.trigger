trigger SiteLinkAccountTrigger on Account(before insert, before update, after insert, after update) {
    SiteLinkTriggerHandler.handle();
}
