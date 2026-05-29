public class IndirectBoardingQueueable implements Queueable, Database.AllowsCallouts {
    private final Id complianceId;

    public IndirectBoardingQueueable(Id complianceId) {
        this.complianceId = complianceId;
    }

    public void execute(QueueableContext context) {
        IndirectBoardingRouter.processCompliance(complianceId);
    }
}