CREATE Function [dbo].[ChargeData](@StartDate datetime, @EndDate datetime, @InOutFlow INT) -- @InOutFlow 0 both, 1 inflow, 2 outflow, , 3 both inflows & outflows but action done from POS only       
RETURNS TABLE          
AS          
          
          
RETURN(          
SELECT                  
 *,           
 Delivery + ManualDiscount + PackageDiscount + CouponDiscount + ConvFeeDiscount + ReturnCredits + Deposits + UsedDeposits AS ChargesDiscounts,           
    Base + BoxOfficeFee + Delivery + ManualDiscount + PackageDiscount + CouponDiscount + ConvFeeDiscount + Package + ReturnCredits + Deposits + UsedDeposits AS Gross,           
    Base + BoxOfficeFee + Delivery + ManualDiscount + PackageDiscount + CouponDiscount + ConvFeeDiscount + Package + ReturnCredits + Deposits + UsedDeposits - UtixFee AS Net          
FROM                      
 (SELECT                  
  ChargeID,           
  ETicketID,           
  DateCharged,           
  RecordLocator,           
  ReservationID,           
  RecordedBy,           
  PackageSaleID,           
          
  CAST(isnull([1], 0) AS DECIMAL(18, 2)) Base,           
  CAST(isnull([2], 0) AS DECIMAL(18, 2)) BoxOfficeFee,           
  CAST(isnull([3], 0) AS DECIMAL(18, 2)) Delivery,           
  CAST(isnull([4], 0) AS DECIMAL(18, 2)) ManualDiscount,           
  CAST(isnull([5], 0) AS DECIMAL(18, 2)) PackageDiscount,           
  CAST(isnull([6], 0) AS DECIMAL(18, 2)) UtixFee,           
  CAST(isnull([8], 0) AS DECIMAL(18, 2)) CouponDiscount,           
  CAST(isnull([7], 0) AS DECIMAL(18, 2)) Package,           
        CAST(isnull([9], 0) AS DECIMAL(18, 2)) ConvFeeDiscount,           
  CAST(isnull([10], 0) AS DECIMAL(18, 2)) ReturnCredits,          
  CAST(isnull([11], 0) AS DECIMAL(18, 2)) Deposits,          
  CAST(isnull([12], 0) AS DECIMAL(18, 2)) UsedDeposits,          
  PaymentID         
      
     FROM                      
  ( SELECT charges.* FROM Charges    
  JOIN TransactionTypes tt ON charges.TransactionTypeID = tt.TransactionTypeID         
   WHERE (@InOutFlow = 0   
   OR (@InOutFlow = 1 AND inflow  = 1)   
   OR (@InOutFlow = 2  AND inflow  = 0 )   
  -- OR (@InOutFlow = 2 AND Amount = 0 and isnull(TransactionTypeID,0) in (2,3,4,6,8) )   
   OR (@InOutFlow = 3 AND isnull(charges.TransactionTypeID, 0)   <    >   1)  
   )          
   AND DateCharged   >  = @StartDate          
   AND DateCharged   <  = @EndDate           
  ) tCharges          
  PIVOT (SUM(Amount) FOR ChargeTypeID IN ([1], [2], [3], [4], [5], [6], [8], [7], [9], [10], [11], [12])) AS pvt          
 ) t          
WHERE                  
 RecordLocator IS NOT NULL          
)     
  
  