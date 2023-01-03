-- Procedure  
CREATE PROCEDURE [dbo].[ReportMonthlyFinancials]
 @month VARCHAR(2)
	,@Year VARCHAR(4)
AS
-- no idea why this works,                                                             
-- but it helps VisualStudio see the temp table                                                            
IF 1 = 0
BEGIN
	SET FMTONLY OFF
END

DECLARE @StartDate DATETIME
	,@EndDate DATETIME

SET @StartDate = @year + '-' + @month + '-01 00:00'
SET @EndDate = dateAdd(second, - 1, DATEADD(month, 1, @StartDate))
SET @StartDate = dbo.ConvertToStandardTimeZone(@StartDate)
SET @EndDate = DateAdd(millisecond, 998, dbo.ConvertToStandardTimeZone(@EndDate))
SET @EndDate = DateAdd(second, 59, @EndDate);

DECLARE @ff VARCHAR(5) = 'false'

SELECT @ff = value
FROM tbl_Configs
WHERE name = 'Pay additional amount with any payment method on single ticket exchange'

SELECT TOP 0 *
INTO #TmpMonthly
FROM dbo.ReportMonthlySettlementDetail(@startDate, @EndDate)

IF @ff = 'true'
BEGIN
	INSERT INTO #TmpMonthly
	SELECT *
	FROM dbo.ReportMonthlySettlementDetail2(@startDate, @EndDate)
END
ELSE
BEGIN
	INSERT INTO #TmpMonthly
	SELECT *
	FROM dbo.ReportMonthlySettlementDetail(@startDate, @EndDate)
END

CREATE NONCLUSTERED INDEX idx_tmpMonthly ON #TmpMonthly (
	RecordLocator
	,chargeTypeID
	,EticketID
	,PackageSaleID
	)

DECLARE @RL VARCHAR(6)
	,@CCFees MONEY

DECLARE cr_CCFees CURSOR
FOR
SELECT RecordLocator
	,sum(amount)
FROM ChargeDetails
WHERE amount > 0
	AND chargeTypeID IN (
		13
		,14
		)
	AND DateCharged > = @StartDate
	AND DateCharged < = @EndDate
GROUP BY RecordLocator

OPEN cr_CCFees

FETCH NEXT
FROM cr_CCFees
INTO @RL
	,@CCFees

WHILE @@FETCH_STATUS = 0
BEGIN
	DECLARE @itemID INT = 0
		,@Orderby INT
		,@grossAmt MONEY = 0
		,@amtUsed MONEY = 0
		,@TotalRLAmount MONEY = 0

	SELECT @TotalRLAmount = isnull(sum(isnull(gross, 0)), 0)
	FROM #TmpMonthly
	WHERE payment_method_fk IN (
			1
			,7
			)
		AND RecordLocator = @RL
		AND gross > 0
		AND TransactionTypeID = 1

	DECLARE cr_itemsToapplyFee CURSOR
	FOR
	SELECT CASE 
			WHEN orderby = 1
				THEN EticketID
			WHEN orderby = 2
				THEN PackageSaleID
			WHEN orderby = 3
				THEN chargeTypeID
			WHEN orderby = 5
				THEN GiftCertificateID
			END ItemID
		,gross
		,orderby
	FROM #TmpMonthly
	WHERE payment_method_fk IN (
			1
			,7
			)
		AND RecordLocator = @RL
		AND gross > 0
		AND TransactionTypeID = 1
	ORDER BY orderby

	OPEN cr_itemsToapplyFee

	FETCH NEXT
	FROM cr_itemsToapplyFee
	INTO @itemID
		,@grossAmt
		,@Orderby

	DECLARE @iterator INT = 1

	WHILE @@FETCH_STATUS = 0
	BEGIN
		IF (
				SELECT count(*)
				FROM #TmpMonthly
				WHERE payment_method_fk IN (
						1
						,7
						)
					AND RecordLocator = @RL
					AND gross > 0
					AND TransactionTypeID = 1
				) = @iterator
		BEGIN
			UPDATE #TmpMonthly
			SET CreditCardFees = @CCFees - @amtUsed
			WHERE (
					(
						@Orderby = 1
						AND EticketID = @itemID
						)
					OR (
						@Orderby = 2
						AND PackageSaleID = @itemID
						AND EticketID = 0
						AND chargeTypeID = 0
						)
					OR (
						@Orderby = 3
						AND chargeTypeID = @itemID
						)
					OR (
						@Orderby = 5
						AND GiftCertificateID = @itemID
						)
					)
				AND payment_method_fk IN (
					1
					,7
					)
				AND RecordLocator = @RL
				AND gross > 0
				AND TransactionTypeID = 1
		END
		ELSE
		BEGIN
			SET @amtUsed = @amtUsed + cast((@grossAmt / @TotalRLAmount) * @CCFees AS DECIMAL(18, 2))

			UPDATE #TmpMonthly
			SET CreditCardFees = cast((@grossAmt / @TotalRLAmount) * @CCFees AS DECIMAL(18, 2))
			WHERE (
					(
						@Orderby = 1
						AND EticketID = @itemID
						)
					OR (
						@Orderby = 2
						AND PackageSaleID = @itemID
						AND EticketID = 0
						AND chargeTypeID = 0
						)
					OR (
						@Orderby = 3
						AND chargeTypeID = @itemID
						)
					OR (
						@Orderby = 5
						AND GiftCertificateID = @itemID
						)
					)
				AND payment_method_fk IN (
					1
					,7
					)
				AND RecordLocator = @RL
				AND gross > 0
				AND TransactionTypeID = 1
		END

		SET @iterator = @iterator + 1

		FETCH NEXT
		FROM cr_itemsToapplyFee
		INTO @itemID
			,@grossAmt
			,@Orderby
	END

	CLOSE cr_itemsToapplyFee;

	DEALLOCATE cr_itemsToapplyFee;

	FETCH NEXT
	FROM cr_CCFees
	INTO @RL
		,@CCFees
END

CLOSE cr_CCFees;

DEALLOCATE cr_CCFees;

SELECT *
FROM (
	--TicketLevel              
	SELECT 1 OrderBy
		,Item
		,SUM(Base) + SUM(Package) Base
		,SUM(BoxOfficeFee) BoxOfficeFee
		,SUM(Delivery) Delivery
		,SUM(ManualDiscount) ManualDiscount
		,SUM(PackageDiscount) PackageDiscount
		,SUM(UtixFee) UtixFee
		,SUM(CouponDiscount) CouponDiscount
		,SUM(Package) Package
		,SUM(ConvFeeDiscount) ConvFeeDiscount
		,SUM(ReturnCredits) ReturnCredits
		,SUM(ISNULL(Quantity, 0)) Quantity
		,AccountNumber
		,SUM(ChargesDiscounts) ChargesDiscounts
		,SUM(Gross) Gross
		,SUM(Net) Net
		,PayMethod
		,TicketType.user_type TicketType
		,Sum(cast(isnull(CreditCardFees, 0) AS DECIMAL(18, 2))) CreditCardFees
		,SUM(Gross) - SUM(UtixFee) - Sum(cast(isnull(CreditCardFees, 0) AS DECIMAL(18, 2))) TotalNet
		,tCharges.payment_method_fk
		,tCharges.RecordLocator
	FROM #TmpMonthly tCharges
	LEFT JOIN etickets ON Etickets.pkid = tCharges.ETicketID
	LEFT JOIN tbl_User_types TicketType ON TicketType.pkid = ETickets.UserTypeIDFK
	WHERE tCharges.orderby = 1
	GROUP BY Item
		,AccountNumber
		,PayMethod
		,tCharges.payment_method_fk
		,TicketType.user_type
		,tCharges.RecordLocator
	
	UNION ALL
	
	---PkgLevel              
	SELECT 2 OrderBy
		,Item
		,SUM(Base) + SUM(Package) Base
		,SUM(BoxOfficeFee) BoxOfficeFee
		,SUM(Delivery) Delivery
		,SUM(ManualDiscount) ManualDiscount
		,SUM(PackageDiscount) PackageDiscount
		,SUM(UtixFee) UtixFee
		,SUM(CouponDiscount) CouponDiscount
		,SUM(Package) Package
		,SUM(ConvFeeDiscount) ConvFeeDiscount
		,SUM(ReturnCredits) ReturnCredits
		,SUM(ISNULL(Quantity, 0)) Quantity
		,AccountNumber AS AccountNumber
		,SUM(ChargesDiscounts) ChargesDiscounts
		,SUM(Gross) Gross
		,SUM(Net) Net
		,PayMethod
		,TicketType.user_type TicketType
		,Sum(cast(isnull(CreditCardFees, 0) AS DECIMAL(18, 2))) CreditCardFees
		,SUM(Gross) - SUM(UtixFee) - Sum(cast(isnull(CreditCardFees, 0) AS DECIMAL(18, 2))) TotalNet
		,tCharges.payment_method_fk
		,tCharges.RecordLocator
	FROM #TmpMonthly tCharges
	LEFT JOIN Etickets ON ETickets.pkid = tCharges.ETicketID
	LEFT JOIN tbl_User_types TicketType ON TicketType.pkid = ETickets.UserTypeIDFK
	WHERE tCharges.orderby = 2
	GROUP BY Item
		,AccountNumber
		,PayMethod
		,tCharges.payment_method_fk
		,TicketType.user_type
		,tCharges.RecordLocator
	
	UNION ALL
	
	---OrderLevel              
	SELECT 3 OrderBy
		,Item
		,SUM(Base) + SUM(Package) Base
		,SUM(BoxOfficeFee) BoxOfficeFee
		,SUM(Delivery) Delivery
		,SUM(ManualDiscount) ManualDiscount
		,SUM(PackageDiscount) PackageDiscount
		,SUM(UtixFee) UtixFee
		,SUM(CouponDiscount) CouponDiscount
		,SUM(Package) Package
		,SUM(ConvFeeDiscount) ConvFeeDiscount
		,SUM(ReturnCredits) ReturnCredits
		,0 Quantity
		,AccountNumber AS AccountNumber
		,SUM(ChargesDiscounts) ChargesDiscounts
		,SUM(Gross) Gross
		,SUM(Net) Net
		,PayMethod
		,'' TicketType
		,Sum(cast(isnull(CreditCardFees, 0) AS DECIMAL(18, 2))) CreditCardFees
		,SUM(Gross) - SUM(UtixFee) - Sum(cast(isnull(CreditCardFees, 0) AS DECIMAL(18, 2))) TotalNet
		,tCharges.payment_method_fk
		,tCharges.RecordLocator
	FROM #TmpMonthly tCharges
	WHERE tCharges.orderby = 3
	GROUP BY Item
		,AccountNumber
		,PayMethod
		,tCharges.payment_method_fk
		,tCharges.RecordLocator
	
	UNION ALL
	
	-- Gift Certificates            
	SELECT 4 OrderBy
		,Item
		,0 Base
		,0 BoxOfficeFee
		,0 Delivery
		,0 ManualDiscount
		,0 PackageDiscount
		,0 UtixFee
		,0 CouponDiscount
		,0 Package
		,0 ConvFeeDiscount
		,SUM(ReturnCredits) ReturnCredits
		,Sum(tCharges.Quantity) Quantity
		,AccountNumber
		,0 ChargesDiscounts
		,SUM(Gross) Gross
		,SUM(Net) Net
		,PayMethod
		,'' TicketType
		,SUM(CAST(ISNULL(CreditCardFees, 0) AS DECIMAL(18, 2))) CreditCardFees
		,SUM(Gross) - SUM(UtixFee) - SUM(CAST(ISNULL(CreditCardFees, 0) AS DECIMAL(18, 2))) TotalNet
		,tPayMethods.pkid
		,tCharges.RecordLocator
	FROM #TmpMonthly tCharges
	LEFT JOIN PaymentMethods tPayMethods ON tPayMethods.pkid = tCharges.payment_method_fk
	WHERE tCharges.orderby = 5
	GROUP BY tPayMethods.pkid
		,PayMethod
		,Item
		,AccountNumber
		,tCharges.RecordLocator
	) a
ORDER BY Item
	,AccountNumber
	,PayMethod
	,TicketType
