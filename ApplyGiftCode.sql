Create PROCEDURE [dbo].[ApplyGiftCode
] @session_id VARCHAR(50)
	,@UserID INT
	,@IsPOS BIT
	,@GiftCode VARCHAR(1000)
	,@OrderLevelCSV VARCHAR(100) --3:5|2:3|4:-3                   
	,@ChargeConvFee BIT
	,@Amount MONEY OUT
	,@Message VARCHAR(255) OUT
AS
SET @GiftCode = replace(@GiftCode, '-', '')

DECLARE @currentDateTime DATETIME = getDate()

IF NOT EXISTS (
		SELECT *
		FROM giftcertificates
		WHERE token IN (
				SELECT value
				FROM dbo.fn_Split(@GiftCode, ',')
				)
		)
BEGIN
	SET @Message = 'Gift certificate does not exist.'
	SET @Amount = 0

	RETURN
END
ELSE IF NOT EXISTS (
		SELECT *
		FROM GiftPrograms
		WHERE programID IN (
				SELECT GiftCertificateProgramID_fk
				FROM giftcertificates
				WHERE token IN (
						SELECT value
						FROM dbo.fn_Split(@GiftCode, ',')
						)
				)
			AND @currentDateTime >= validfrom
			AND @currentDateTime <= validTo
		)
BEGIN
	SET @Message = 'Gift certificate has expired.'
	SET @Amount = 0

	RETURN
END
ELSE IF  EXISTS (
		SELECT *
		FROM GiftPrograms
		WHERE programID IN (
				SELECT GiftCertificateProgramID_fk
				FROM giftcertificates
				WHERE token IN (
						SELECT value
						FROM dbo.fn_Split(@GiftCode, ',')
						)
				)
			AND isnull(POSOnly, 0) = 1
			AND @IsPOS = 0
		)
BEGIN
	SET @Message = 'This gift certificate can be used at POS only.'
	SET @Amount = 0

	RETURN
END
ELSE
BEGIN
	--DECLARE @GCID INT          
	--SELECT @GCID = GiftCertificateID          
	--FROM giftcertificates          
	--WHERE token = @GiftCode          
	--Delete gift certticate if not applied on completed Sale                                                       
	DELETE
	FROM GiftCertificateUsage
	WHERE SessionID = @session_id
		AND userID = @UserID
		AND IsPos = @IsPOS
		AND RL IS NULL

	--AND GiftCertificateID = @GCID               
	---------------Exclude conv fee List all chargeIDS              
	SELECT TOP 0 chargeID
	INTO #ChargeIDs
	FROM charges

	SET IDENTITY_INSERT #ChargeIDs ON

	IF @ChargeConvFee = 0
	BEGIN
		INSERT INTO #ChargeIDs (chargeID)
		SELECT chargeID
		FROM charges chg
		JOIN Etickets etics ON chg.eticketID = etics.pkid
		JOIN tbl_event_tickets Tkt_opt ON tkt_opt.event_id_fk = etics.EventID
		WHERE chg.chargetypeID = 2
			AND Tkt_opt.combine = 0
			AND etics.reservationID IN (
				SELECT pkid
				FROM tbl_reservations
				WHERE session_id = @session_id
					AND user_id_fk = @UserID
					AND pos = @IsPOS
					AND record_locator IS NULL
				)

		INSERT INTO #ChargeIDs (chargeID)
		SELECT chargeID
		FROM charges
		WHERE chargetypeID = 2
			AND isnull(EticketID, 0) = 0
			AND isnull(packageSaleID, 0) = 0
			AND reservationID IN (
				SELECT pkid
				FROM tbl_reservations
				WHERE session_id = @session_id
					AND user_id_fk = @UserID
					AND pos = @IsPOS
					AND record_locator IS NULL
				)

		INSERT INTO #ChargeIDs (chargeID)
		SELECT chargeID
		FROM charges chg
		JOIN packageSales ps ON chg.packageSaleID = ps.packageSaleID
		JOIN packages p ON ps.packageID = p.packageID
		WHERE chg.chargetypeID = 2
			AND isnull(EticketID, 0) = 0
			AND isnull(chg.packageSaleID, 0) <> 0
			AND reservationID IN (
				SELECT pkid
				FROM tbl_reservations
				WHERE session_id = @session_id
					AND user_id_fk = @UserID
					AND pos = @IsPOS
					AND record_locator IS NULL
				)
	END

	SET IDENTITY_INSERT #ChargeIDs OFF

	SELECT TOP 0 chargeID
	INTO #cartOrderIDs
	FROM cartorderCharges

	SET IDENTITY_INSERT #cartOrderIDs ON

	IF @ChargeConvFee = 0
	BEGIN
		INSERT INTO #cartOrderIDs (chargeID)
		SELECT chargeID
		FROM cartorderCharges
		WHERE sessionID = @session_id
			AND userID = @UserID
			AND STATUS = 0
			AND chargetypeID = 2
			AND isnull(PackageSaleID, 0) = 0

		INSERT INTO #cartOrderIDs (chargeID)
		SELECT COC.chargeID
		FROM cartorderCharges COC
		JOIN packageSales ps ON COC.packageSaleID = ps.packageSaleID
		JOIN packages p ON ps.packageID = p.packageID
			AND p.combine = 0
		WHERE COC.sessionID = @session_id
			AND COC.userID = @UserID
			AND COC.STATUS = 0
			AND COC.chargetypeID = 2
			AND isnull(COC.PackageSaleID, 0) <> 0
	END

	---------------End list chargeID for conv fee              
	DECLARE @amt MONEY
		,@eventID VARCHAR(1000)
		,@CatID VARCHAR(1000)
		,@pkgID VARCHAR(1000)
		,@applyonOrderLevel BIT

	--Pick amount of gift certicate                                                  
	SELECT gc.GiftCertificateID
		,isnull(sum(isnull(gct.TransactionAmount, 0)), 0) GCAmount
		,cast(0 AS MONEY) amountUsed
		,ROW_NUMBER() OVER (
			ORDER BY position ASC
			) AS Row
	INTO #GCIDWithAmount
	FROM giftcertificates gc
	JOIN GiftCertificateTransactions gct ON gc.GiftCertificateID = gct.giftcertificateID
	JOIN dbo.fn_Split(@GiftCode, ',') gcSplitOuter ON gc.Token = gcSplitOuter.value
	WHERE token IN (
			SELECT DISTINCT value
			FROM dbo.fn_Split(@GiftCode, ',') gcSplit
			JOIN GiftCertificates gcInner ON gcInner.Token = gcsplit.value
			JOIN GiftPrograms gcp ON gcp.ProgramID = gcInner.GiftCertificateProgramID_fk
			WHERE @currentDateTime >= validfrom
				AND @currentDateTime <= validTo
			)
		AND isnull(gc.IsGCReturned, 0) = 0
	GROUP BY gc.GiftCertificateID
		,gcSplitOuter.position

	DECLARE @netAmt MONEY
		,@gcAmount MONEY
		,@GCID INT
		,@amountToInsert MONEY = 0

	SELECT @amt = sum(GCAmount)
	FROM #GCIDWithAmount
	WHERE (GCAmount - amountUsed) > 0

	SET @netAmt = @amt

	IF @amt > 0
	BEGIN
		--Pick those event/packages/categories from cart on which gift certificate is applicable                                                       
		DECLARE curGC CURSOR
		FOR
		SELECT DISTINCT isnull(gcEvnts.EventID, '-1') EventID
			,isnull(GcCat.CategoryID, '-1') CategoryID
			,isnull(GCPkg.PackageID, '-1') PackageID
			,isnull(Gp.ApplyOnOrderLevelCharges, 0) ApplyOnOrderLevelCharges
		FROM Giftcertificates GC
		JOIN GiftPrograms GP ON GC.GiftCertificateProgramID_fk = gp.ProgramID
		LEFT JOIN GiftCertificateProgramEvents gcEvnts ON gcEvnts.ProgramID = gp.ProgramID
			AND (
				isnull(gcEvnts.EventID, 0) = 0
				OR gcEvnts.EventID IN (
					SELECT event_id_fk
					FROM tbl_reservations
					WHERE session_id = @session_id
						AND user_id_fk = @UserID
						AND pos = @IsPOS
						AND isnull(packageID, 0) = 0
						AND record_locator IS NULL
					)
				)
			AND isnull(gcEvnts.EventID, 0) <> - 1
		LEFT JOIN GiftCertificateProgramCategories GcCat ON GcCat.ProgramID = gp.ProgramID
			AND (
				isnull(GcCat.CategoryID, 0) = 0
				OR GcCat.CategoryID IN (
					SELECT tbl_categories_events.category_id_fk
					FROM tbl_reservations
					JOIN tbl_categories_events ON tbl_reservations.event_id_fk = tbl_categories_events.event_id_fk
					WHERE session_id = @session_id
						AND user_id_fk = @UserID
						AND pos = @IsPOS
						AND isnull(packageID, 0) = 0
						AND record_locator IS NULL
					)
				)
			AND isnull(GcCat.CategoryID, 0) <> - 1
		LEFT JOIN GiftCertificateProgramPackages GCPkg ON GCPkg.ProgramID = gp.ProgramID
			AND (
				isnull(GCPkg.PackageID, 0) = 0
				OR GCPkg.PackageID IN (
					SELECT PackageID
					FROM tbl_reservations
					WHERE session_id = @session_id
						AND user_id_fk = @UserID
						AND pos = @IsPOS
						AND record_locator IS NULL
					)
				)
			AND isnull(GCPkg.PackageID, 0) <> - 1
		WHERE token IN (
				SELECT DISTINCT value
				FROM dbo.fn_Split(@GiftCode, ',') gcSplit
				JOIN GiftCertificates gcInner ON gcInner.Token = gcsplit.value
				JOIN GiftPrograms gcp ON gcp.ProgramID = gcInner.GiftCertificateProgramID_fk
				WHERE @currentDateTime >= validfrom
					AND @currentDateTime <= validTo
				)

		OPEN curGC

		FETCH NEXT
		FROM curGC
		INTO @eventID
			,@CatID
			,@pkgID
			,@applyonOrderLevel

		WHILE @@FETCH_STATUS = 0
			AND @netAmt > 0
		BEGIN
			-----------Start------Deduct from Single ticket Sale                          
			IF @eventID <> '-1'
				OR @CatID <> '-1'
			BEGIN
				DECLARE @TicketID INT
					,@ticketAmt MONEY = 0

				DECLARE curEventTicketID CURSOR
				FOR
				SELECT e.pkid
					,isnull(sum(isnull(cast(c.amount AS DECIMAL(18, 2)), 0)), 0)
				FROM charges c
				JOIN etickets e ON c.EticketID = e.pkid
				JOIN tbl_categories_events ce ON ce.event_id_fk = e.EventID
				JOIN tbl_reservations r ON r.pkid = e.ReservationID
				JOIN chargeTypes CT ON C.ChargeTypeID = CT.ChargeTypeID
					AND isnull(CT.ClientCharge, 0) = 0
				WHERE r.session_id = @session_id
					AND r.user_id_fk = @UserID
					AND r.pos = @IsPOS
					AND (
						@eventID = 0
						OR e.eventID IN (
							SELECT number
							FROM dbo.ListToTable(@eventID)
							)
						)
					AND (
						@CatID = 0
						OR ce.category_id_fk IN (
							SELECT number
							FROM dbo.ListToTable(@CatID)
							)
						)
					AND (isnull(e.PackagesaleID, 0) = 0)
					AND r.record_locator IS NULL
					AND c.ChargeID NOT IN (
						SELECT isnull(chargeID, 0)
						FROM #ChargeIDs
						)
				GROUP BY e.pkid

				OPEN curEventTicketID

				FETCH NEXT
				FROM curEventTicketID
				INTO @TicketID
					,@ticketAmt

				WHILE @@FETCH_STATUS = 0
				BEGIN
					-- This commented area is no longer required as coupon is already in charges                                      
					--DECLARE @CouponEticketAmount DECIMAL(18, 2) = 0                                      
					--SELECT @CouponEticketAmount = isnull(Sum(isnull(Discountamount, 0)), 0)                           
					--FROM DiscountCodesApplied                                      
					--WHERE EticketID = @TicketID                                      
					--SET @ticketAmt = @ticketAmt - @CouponEticketAmount            
					SET @amountToInsert = 0

					SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
						,@GCID = GiftCertificateID
					FROM #GCIDWithAmount
					WHERE (GCAmount - amountUsed) > 0

					WHILE isnull(@ticketAmt, 0) != 0
						AND @gcAmount > 0
					BEGIN
						IF isnull(@ticketAmt, 0) <= @gcAmount
						BEGIN
							SET @gcAmount = @gcAmount - @ticketAmt
							SET @amountToInsert = @ticketAmt
							SET @ticketAmt = 0
						END
						ELSE
						BEGIN
							SET @ticketAmt = @ticketAmt - @gcAmount
							SET @amountToInsert = @gcAmount
							SET @gcAmount = 0
						END

						UPDATE #GCIDWithAmount
						SET amountUsed = amountUsed + @amountToInsert
						WHERE GiftCertificateID = @GCID

						SET @netAmt = @netAmt - @amountToInsert

						INSERT INTO GiftCertificateUsage (
							GiftCertificateID
							,TIMESTAMP
							,Amount
							,UserID
							,SessionID
							,IsPos
							,EticketID
							,ChargeTypeID
							,PackageSaleID
							,RL
							)
						VALUES (
							@GCID
							,@currentDateTime
							,@amountToInsert
							,@UserID
							,@session_id
							,@IsPOS
							,@TicketID
							,NULL
							,NULL
							,NULL
							)

						SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
							,@GCID = GiftCertificateID
						FROM #GCIDWithAmount
						WHERE (GCAmount - amountUsed) > 0
					END

					FETCH NEXT
					FROM curEventTicketID
					INTO @TicketID
						,@ticketAmt
				END

				CLOSE curEventTicketID;

				DEALLOCATE curEventTicketID;
			END

			-----------End------Deduct from Single Ticket Sale                                                        
			-----------Start------Deduct from Package Sale                                                        
			IF @pkgID <> '-1'
			BEGIN
				DECLARE @PackageSaleID INT
					,@EticketID INT
					,@PackageAmt MONEY = 0

				SELECT 0 EticketID
					,b.packageSaleID
					,CASE 
						WHEN ISNULL(SUM(ISNULL(CAST(Discountamount AS DECIMAL(18, 2)), 0)), 0) <= SUM(b.amt) -- Apply discount if discount is less than amount  
							THEN CAST(((SUM(b.amt) - ISNULL(SUM(ISNULL(CAST(Discountamount AS DECIMAL(18, 2)), 0)), 0))) AS DECIMAL(18, 2))
						ELSE 0 -- if discount is greater than pkg amount at pkg level then apply discount equal to pkg price which will make pkg amount 0  
						END amt
					,CASE 
						WHEN ISNULL(SUM(ISNULL(CAST(Discountamount AS DECIMAL(18, 2)), 0)), 0) <= SUM(b.amt)
							THEN ISNULL(SUM(ISNULL(CAST(Discountamount AS DECIMAL(18, 2)), 0)), 0) -- only amoutn equal to discoutn is discounted.  
						ELSE SUM(b.amt) -- Full amount of pkg priced at pkg level used to give discount  
						END AS DiscountedAmount
				INTO #PkgPricedAtTicketType
				FROM (
					SELECT 0 EticketID
						,a.packageSaleID
						,cast(SUM(a.amt) AS DECIMAL(18, 2)) amt
					FROM (
						SELECT 0 EticketID
							,c.packageSaleID packageSaleID
							,isnull(sum(isnull(cast(c.amount AS DECIMAL(18, 2)), 0)), 0) amt
						FROM charges c
						JOIN chargeTypes CT ON C.ChargeTypeID = CT.ChargeTypeID
							AND isnull(CT.ClientCharge, 0) = 0
						WHERE isnull(c.ETicketID, 0) = 0
							AND isnull(c.PackageSaleID, 0) <> 0
							AND c.PackageSaleID IN (
								SELECT DISTINCT packageSaleID
								FROM etickets
								WHERE isnull(packageID, 0) <> 0
									AND reservationID IN (
										SELECT pkid
										FROM tbl_reservations r
										WHERE r.session_id = @session_id
											AND r.user_id_fk = @UserID
											AND r.pos = @IsPOS
											AND record_locator IS NULL
										)
									AND (
										@pkgID = 0
										OR isnull(packageID, 0) IN (
											SELECT number
											FROM dbo.ListToTable(@pkgID)
											)
										)
								)
							AND c.ChargeID NOT IN (
								SELECT isnull(chargeID, 0)
								FROM #ChargeIDs
								)
						GROUP BY c.packageSaleID
						
						UNION ALL
						
						SELECT 0 EticketID
							,isnull(packageSaleID, 0) packageSaleID
							,isnull(sum(isnull(cast(amount AS DECIMAL(18, 2)), 0)), 0) amt
						FROM CartOrderCharges
						JOIN Packages P ON CartOrderCharges.PackageID = P.PackageID
						JOIN chargeTypes CT ON CartOrderCharges.ChargeTypeID = CT.ChargeTypeID
							AND isnull(CT.ClientCharge, 0) = 0
						WHERE CartOrderCharges.ChargeTypeID = 2
							AND STATUS = 0
							AND SessionID = @session_id
							AND userID = @UserID
							AND isnull(packageSaleID, 0) <> 0
							AND P.PackageFeeType = 2
							AND (
								@pkgID = 0
								OR isnull(p.packageID, 0) IN (
									SELECT number
									FROM dbo.ListToTable(@pkgID)
									)
								)
							AND PackageSaleID IN (
								SELECT DISTINCT packageSaleID
								FROM etickets
								WHERE isnull(packageID, 0) <> 0
									AND reservationID IN (
										SELECT pkid
										FROM tbl_reservations r
										WHERE r.session_id = @session_id
											AND r.user_id_fk = @UserID
											AND r.pos = @IsPOS
											AND record_locator IS NULL
										)
								)
							AND CartOrderCharges.chargeID NOT IN (
								SELECT isnull(chargeID, 0)
								FROM #cartOrderIDs
								)
						GROUP BY isnull(packageSaleID, 0)
						) a
					GROUP BY a.packageSaleID
					) b
				LEFT JOIN DiscountCodesApplied dca ON b.packageSaleID = dca.PackageSaleID
				GROUP BY b.packageSaleID

				SELECT e.pkid EticketID
					,e.PackageSaleID
					,isnull(sum(isnull(cast(c.amount AS DECIMAL(18, 2)), 0)), 0) amt
					,0 DiscountedAmount
				INTO #PkgAtTicketLevel
				FROM charges c
				JOIN etickets e ON c.EticketID = e.pkid
				JOIN tbl_categories_events ce ON ce.event_id_fk = e.EventID
				JOIN tbl_reservations r ON r.pkid = e.ReservationID
				JOIN chargeTypes CT ON C.ChargeTypeID = CT.ChargeTypeID
					AND isnull(CT.ClientCharge, 0) = 0
				--JOIN tbl_event_tickets t ON t.pkid = e.ticketOptionID                                      
				WHERE r.session_id = @session_id
					AND r.user_id_fk = @UserID
					AND r.pos = @IsPOS
					AND (
						@pkgID = 0
						OR isnull(e.packageID, 0) IN (
							SELECT number
							FROM dbo.ListToTable(@pkgID)
							)
						)
					AND isnull(e.PackagesaleID, 0) > 0
					AND isnull(c.eticketID, 0) > 0
					AND r.record_locator IS NULL
					AND c.ChargeID NOT IN (
						SELECT isnull(chargeID, 0)
						FROM #ChargeIDs
						)
					AND c.amount > 0
				GROUP BY e.PackageSaleID
					,e.pkid

				SELECT ROW_NUMBER() OVER (
						ORDER BY PackageSaleID
						) AS rowNum
					,PackageSaleID
				INTO #tmpPkgSaleIds
				FROM (
					SELECT DISTINCT PackageSaleID
					FROM #PkgAtTicketLevel
					) p

				DECLARE @TotalTicketLevelPkgSalesIds INT
					,@pkgIterator INT = 1

				SELECT @TotalTicketLevelPkgSalesIds = count(1)
				FROM #tmpPkgSaleIds

				WHILE @pkgIterator <= @TotalTicketLevelPkgSalesIds
				BEGIN
					DECLARE @PkgDiscountAmount DECIMAL(18, 2)
						,@currentPkgSaleID INT

					SELECT @currentPkgSaleID = packageSaleID
					FROM #tmpPkgSaleIds
					WHERE rowNum = @pkgIterator

					SELECT @PkgDiscountAmount = isnull(Sum(isnull(cast(Discountamount AS DECIMAL(18, 2)), 0)), 0)
					FROM DiscountCodesApplied
					WHERE PackageSaleID = @currentPkgSaleID

					-- Fix obs #6 7262 Subtract discoutn amount already subtracted from total  
					SELECT @PkgDiscountAmount = @PkgDiscountAmount - isnull(sum(DiscountedAmount), 0)
					FROM #PkgPricedAtTicketType
					WHERE packageSaleID = @currentPkgSaleID

					IF isnull(@PkgDiscountAmount, 0) > 0
					BEGIN
						IF OBJECT_ID('tempdb..#CurrentPkgSaleEticketIDS') IS NOT NULL
						BEGIN
							DROP TABLE #CurrentPkgSaleEticketIDS
						END

						SELECT ROW_NUMBER() OVER (
								ORDER BY EticketID
								) AS rowNum
							,*
						INTO #CurrentPkgSaleEticketIDS
						FROM #PkgAtTicketLevel
						WHERE PackageSaleID = @currentPkgSaleID

						DECLARE @currentPkgSaleEticketCount INT = 0
							,@tktIterator INT = 1

						SELECT @currentPkgSaleEticketCount = count(*)
						FROM #CurrentPkgSaleEticketIDS

						WHILE @tktIterator <= @currentPkgSaleEticketCount
						BEGIN
							DECLARE @TicketAmtInPkg MONEY
								,@amountToUpdate MONEY
								,@pkgTicketID INT
								,@pkgPkgSaleID INT

							SELECT @pkgTicketID = EticketID
								,@pkgPkgSaleID = packagesaleID
								,@TicketAmtInPkg = amt
							FROM #CurrentPkgSaleEticketIDS
							WHERE rowNum = @tktIterator

							IF @TicketAmtInPkg >= @PkgDiscountAmount
							BEGIN
								SET @amountToUpdate = @PkgDiscountAmount
								SET @PkgDiscountAmount = 0
							END
							ELSE IF @TicketAmtInPkg < @PkgDiscountAmount
							BEGIN
								SET @amountToUpdate = @TicketAmtInPkg
								SET @PkgDiscountAmount = @PkgDiscountAmount - @TicketAmtInPkg
							END

							UPDATE #CurrentPkgSaleEticketIDS
							SET amt = @amountToUpdate
							WHERE rowNum = @tktIterator

							UPDATE #PkgAtTicketLevel
							SET amt = amt - @amountToUpdate
							WHERE eticketID = @pkgTicketID
								AND packagesaleID = @pkgPkgSaleID

							SET @tktIterator = @tktIterator + 1
						END
					END

					SET @pkgIterator = @pkgIterator + 1
				END

				DECLARE curPkgSaleID CURSOR
				FOR
				SELECT EticketID
					,packageSaleID
					,sum(amt)
				FROM (
					SELECT *
					FROM #PkgPricedAtTicketType
					
					UNION ALL
					
					SELECT *
					FROM #PkgAtTicketLevel
					) a
				GROUP BY packageSaleID
					,EticketID
				ORDER BY EticketID

				OPEN curPkgSaleID

				FETCH NEXT
				FROM curPkgSaleID
				INTO @EticketID
					,@PackageSaleID
					,@PackageAmt

				--DECLARE @PkgSaleIds VARCHAR(100) = ''    
				--IF isnull(@EticketID, 0) > 0                  
				-- AND @PackageAmt > 0                  
				--BEGIN                  
				-- SET @PkgSaleIds = cast(@PackageSaleID AS VARCHAR(10))                  
				--END                  
				WHILE @@FETCH_STATUS = 0
				BEGIN
					--DECLARE @CouponPackageAmount DECIMAL(18, 2) = 0    
					--SELECT @CouponPackageAmount = isnull(Sum(isnull(cast(Discountamount AS DECIMAL(18, 2)), 0)), 0)    
					--FROM DiscountCodesApplied    
					--WHERE PackageSaleID = @PackageSaleID    
					--IF @CouponPackageAmount > 0    
					--BEGIN    
					-- IF NOT EXISTS (    
					--   SELECT *    
					--   FROM dbo.ListToTable(@PkgSaleIds)    
					--   WHERE number = @PackageSaleID    
					--   )    
					-- BEGIN    
					--  SET @PkgSaleIds = @PkgSaleIds + ',' + cast(@PackageSaleID AS VARCHAR(10))    
					--  SET @netAmt = @netAmt + @CouponPackageAmount    
					-- END    
					--END    
					SET @amountToInsert = 0

					SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
						,@GCID = GiftCertificateID
					FROM #GCIDWithAmount
					WHERE (GCAmount - amountUsed) > 0

					WHILE @gcAmount > 0
						AND isnull(@PackageAmt, 0) > 0
					BEGIN
						--                         
						IF @PackageAmt <= @gcAmount
						BEGIN
							SET @gcAmount = @gcAmount - @PackageAmt
							SET @amountToInsert = @PackageAmt
							SET @PackageAmt = 0
						END
						ELSE
						BEGIN
							SET @PackageAmt = @PackageAmt - @gcAmount
							SET @amountToInsert = @gcAmount
							SET @gcAmount = 0
						END

						UPDATE #GCIDWithAmount
						SET amountUsed = amountUsed + @amountToInsert
						WHERE GiftCertificateID = @GCID

						SET @netAmt = @netAmt - @amountToInsert

						INSERT INTO GiftCertificateUsage (
							GiftCertificateID
							,TIMESTAMP
							,Amount
							,UserID
							,SessionID
							,IsPos
							,EticketID
							,ChargeTypeID
							,PackageSaleID
							,RL
							)
						VALUES (
							@GCID
							,@currentDateTime
							,@amountToInsert
							,@UserID
							,@session_id
							,@IsPOS
							,@EticketID
							,NULL
							,@PackageSaleID
							,NULL
							)

						SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
							,@GCID = GiftCertificateID
						FROM #GCIDWithAmount
						WHERE (GCAmount - amountUsed) > 0
					END

					FETCH NEXT
					FROM curPkgSaleID
					INTO @EticketID
						,@PackageSaleID
						,@PackageAmt
				END

				--INSERT INTO GiftCertificateUsage (    
				-- GiftCertificateID    
				-- ,TIMESTAMP    
				-- ,Amount    
				-- ,UserID    
				-- ,SessionID    
				-- ,IsPos    
				-- ,EticketID    
				-- ,ChargeTypeID    
				-- ,PackageSaleID    
				-- ,RL    
				-- )    
				--SELECT DISTINCT @GCID    
				-- ,@currentDateTime    
				-- ,DiscountAmount * - 1    
				-- ,@UserID    
				-- ,@session_id    
				-- ,@IsPOS    
				-- ,NULL    
				-- ,NULL    
				-- ,PackageSaleID    
				-- ,NULL    
				--FROM DiscountCodesApplied    
				--WHERE packageSaleId IN (    
				--  SELECT *    
				--  FROM dbo.ListToTable(@PkgSaleIds)    
				--  )    
				-- AND session_id = @session_id    
				-- AND isnull(discountamount, 0) <> 0    
				CLOSE curPkgSaleID

				DEALLOCATE curPkgSaleID
			END

			-----------End------Deduct from Package Sale                                                        
			----Start Deduct From Order Level Charge                                                      
			IF @applyonOrderLevel = 1
				AND LEN(@OrderLevelCSV) > 1
			BEGIN
				DECLARE @ChargeTypeID INT
					,@ChargeAmt MONEY = 0

				DECLARE curOrderLevelCharges CURSOR
				FOR
				SELECT SUBSTRING(value, 0, CHARINDEX(':', value)) ChargeTYpeID
					,SUBSTRING(value, CHARINDEX(':', value) + 1, 100) ChargeValue
				FROM dbo.fn_Split(@OrderLevelCSV, '|')

				OPEN curOrderLevelCharges

				FETCH NEXT
				FROM curOrderLevelCharges
				INTO @ChargeTypeID
					,@ChargeAmt

				WHILE @@FETCH_STATUS = 0
				BEGIN
					SET @amountToInsert = 0

					SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
						,@GCID = GiftCertificateID
					FROM #GCIDWithAmount
					WHERE (GCAmount - amountUsed) > 0

					WHILE @gcAmount > 0
						AND isnull(@ChargeAmt, 0) != 0
					BEGIN
						IF @ChargeAmt <= @gcAmount
						BEGIN
							SET @gcAmount = @gcAmount - @ChargeAmt
							SET @amountToInsert = @ChargeAmt
							SET @ChargeAmt = 0
						END
						ELSE
						BEGIN
							SET @ChargeAmt = @ChargeAmt - @gcAmount
							SET @amountToInsert = @gcAmount
							SET @gcAmount = 0
						END

						UPDATE #GCIDWithAmount
						SET amountUsed = amountUsed + @amountToInsert
						WHERE GiftCertificateID = @GCID

						SET @netAmt = @netAmt - @amountToInsert

						INSERT INTO GiftCertificateUsage (
							GiftCertificateID
							,TIMESTAMP
							,Amount
							,UserID
							,SessionID
							,IsPos
							,EticketID
							,ChargeTypeID
							,PackageSaleID
							,RL
							)
						VALUES (
							@GCID
							,@currentDateTime
							,@amountToInsert
							,@UserID
							,@session_id
							,@IsPOS
							,NULL
							,@ChargeTypeID
							,NULL
							,NULL
							)

						SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
							,@GCID = GiftCertificateID
						FROM #GCIDWithAmount
						WHERE (GCAmount - amountUsed) > 0
					END

					FETCH NEXT
					FROM curOrderLevelCharges
					INTO @ChargeTypeID
						,@ChargeAmt
				END

				CLOSE curOrderLevelCharges

				DEALLOCATE curOrderLevelCharges
			END

			----End Deduct From Order Level Charge                                                  
			--- Start Handling for Order Level Conv Fee                                               
			IF @applyonOrderLevel = 1
			BEGIN
				DECLARE @OrderLevelConvFee MONEY

				SELECT @OrderLevelConvFee = sum(cast(amount AS DECIMAL(18, 2)))
				FROM CartOrderCharges
				JOIN Packages P ON CartOrderCharges.PackageID = P.PackageID
				JOIN chargeTypes CT ON CartOrderCharges.ChargeTypeID = CT.ChargeTypeID
					AND isnull(CT.ClientCharge, 0) = 0
				WHERE CartOrderCharges.ChargeTypeID = 2
					AND STATUS = 0
					AND SessionID = @session_id
					AND userID = @UserID
					AND (
						isnull(packageSaleID, 0) = 0
						OR (
							isnull(packageSaleID, 0) <> 0
							AND P.PackageFeeType = 1
							)
						)
					AND CartOrderCharges.chargeID NOT IN (
						SELECT isnull(chargeID, 0)
						FROM #cartOrderIDs
						)

				SET @amountToInsert = 0

				SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
					,@GCID = GiftCertificateID
				FROM #GCIDWithAmount
				WHERE (GCAmount - amountUsed) > 0

				WHILE @gcAmount > 0
					AND isnull(@OrderLevelConvFee, 0) != 0
				BEGIN
					IF @OrderLevelConvFee <= @gcAmount
					BEGIN
						SET @gcAmount = @gcAmount - @OrderLevelConvFee
						SET @amountToInsert = @OrderLevelConvFee
						SET @OrderLevelConvFee = 0
					END
					ELSE
					BEGIN
						SET @OrderLevelConvFee = @OrderLevelConvFee - @gcAmount
						SET @amountToInsert = @gcAmount
						SET @gcAmount = 0
					END

					UPDATE #GCIDWithAmount
					SET amountUsed = amountUsed + @amountToInsert
					WHERE GiftCertificateID = @GCID

					SET @netAmt = @netAmt - @ticketAmt

					INSERT INTO GiftCertificateUsage (
						GiftCertificateID
						,TIMESTAMP
						,Amount
						,UserID
						,SessionID
						,IsPos
						,EticketID
						,ChargeTypeID
						,PackageSaleID
						,RL
						)
					VALUES (
						@GCID
						,@currentDateTime
						,@amountToInsert
						,@UserID
						,@session_id
						,@IsPOS
						,NULL
						,2
						,NULL
						,NULL
						)

					SELECT TOP 1 @gcAmount = (GCAmount - amountUsed)
						,@GCID = GiftCertificateID
					FROM #GCIDWithAmount
					WHERE (GCAmount - amountUsed) > 0
				END
			END

			--- End Handling for Order Level Conv Fee                                                      
			FETCH NEXT
			FROM curGC
			INTO @eventID
				,@CatID
				,@pkgID
				,@applyonOrderLevel
		END

		CLOSE curGC

		DEALLOCATE curGC

		SELECT @Amount = isnull(sum(cast(isnull(Amount, 0) AS DECIMAL(18, 2))), 0)
		FROM GiftCertificateUsage
		WHERE SessionID = @session_id
			AND UserID = @UserID
			AND IsPos = @IsPOS
			AND RL IS NULL
	END
	ELSE
	BEGIN
		SET @Message = 'Gift certificate is fully used out. Please purchase new certificate.'
		SET @Amount = 0

		RETURN
	END
END

